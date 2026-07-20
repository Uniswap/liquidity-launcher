// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {BondingCurveLaunchStrategy} from "../../../../src/strategies/BondingCurveLaunchStrategy.sol";
import {BondingCurveLaunchHook} from "../../../../src/periphery/hooks/BondingCurveLaunchHook.sol";
import {IBondingCurveLaunchHook} from "../../../../src/interfaces/IBondingCurveLaunchHook.sol";
import {MockERC20} from "../../../mocks/MockERC20.sol";

/// @notice A launched token with 6 decimals, used to exercise the decimals guard.
contract MockBondingSixDecimalToken is ERC20 {
    constructor(uint256 supply, address recipient) ERC20("Six Decimal Token", "SIX") {
        _mint(recipient, supply);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

/// @notice A token that delivers one wei less than requested, used to exercise the fee-on-transfer guard.
contract MockBondingShortTransferToken is ERC20 {
    constructor(uint256 supply, address recipient) ERC20("Short Transfer Token", "SHORT") {
        _mint(recipient, supply);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        _spendAllowance(from, _msgSender(), value);
        _transfer(from, to, value - 1);
        return true;
    }
}

/// @notice Shared fixture for BondingCurveLaunchStrategy unit tests. Deploys the real v4 PoolManager /
///         PositionManager and a mined hook bound to the strategy. `launcher` is this test contract,
///         so it can drive `initializeDistribution` directly.
abstract contract BondingCurveLaunchTestBase is Test {
    IPoolManager internal constant POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IPositionManager internal constant POSITION_MANAGER = IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);

    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000 ether;
    int24 internal constant INITIAL_TICK = 122_000;
    int24 internal constant GRADUATION_TICK = 94_200;
    uint160 internal constant HOOK_FLAGS =
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG;

    address internal launcher = address(this);
    IPoolManager internal poolManager = POOL_MANAGER;
    IPositionManager internal positionManager = POSITION_MANAGER;
    BondingCurveLaunchHook internal launchHook;
    BondingCurveLaunchStrategy internal strategy;

    function setUp() public virtual {
        deployCodeTo("lib/v4-core/src/PoolManager.sol:PoolManager", abi.encode(address(this)), address(POOL_MANAGER));
        deployCodeTo(
            "lib/v4-periphery/src/PositionManager.sol:PositionManager",
            abi.encode(POOL_MANAGER, address(0), uint256(0), address(0), address(0)),
            address(POSITION_MANAGER)
        );

        address predictedStrategy = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(this),
            HOOK_FLAGS,
            type(BondingCurveLaunchHook).creationCode,
            abi.encode(POOL_MANAGER, POSITION_MANAGER, predictedStrategy)
        );
        strategy = new BondingCurveLaunchStrategy(
            launcher,
            POSITION_MANAGER,
            POOL_MANAGER,
            IBondingCurveLaunchHook(hookAddress),
            INITIAL_TICK,
            GRADUATION_TICK
        );
        assertEq(address(strategy), predictedStrategy);
        launchHook = new BondingCurveLaunchHook{salt: salt}(POOL_MANAGER, POSITION_MANAGER, address(strategy));
        assertEq(address(launchHook), hookAddress);
        vm.deal(address(this), 100_000 ether);
    }

    /// @notice Deploys a strategy with the given ticks and the shared collaborators (used by constructor tests).
    function _deployStrategy(int24 initialTick, int24 graduationTick) internal returns (BondingCurveLaunchStrategy) {
        return new BondingCurveLaunchStrategy(
            launcher, POSITION_MANAGER, POOL_MANAGER, launchHook, initialTick, graduationTick
        );
    }

    /// @notice Mints a fresh 1B-supply / 18-decimal token to this contract.
    function _deployToken(uint256 supply) internal returns (MockERC20) {
        return new MockERC20("Bonding Token", "BOND", supply, address(this));
    }

    /// @notice Approves and launches `token` through the strategy as the launcher.
    function _initialize(IERC20 token, uint256 totalSupply, bytes memory configData) internal {
        token.approve(address(strategy), totalSupply);
        strategy.initializeDistribution(address(token), totalSupply, configData, bytes32(0));
    }

    receive() external payable {}
}
