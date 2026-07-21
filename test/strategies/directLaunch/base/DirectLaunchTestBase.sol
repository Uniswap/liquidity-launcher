// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {DirectLaunchStrategy} from "../../../../src/strategies/DirectLaunchStrategy.sol";
import {MockERC20} from "../../../mocks/MockERC20.sol";

/// @notice A launched token with 6 decimals, used to exercise the decimals guard.
contract MockDirectSixDecimalToken is ERC20 {
    constructor(uint256 supply, address recipient) ERC20("Six Decimal Token", "SIX") {
        _mint(recipient, supply);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

/// @notice A token that delivers one wei less than requested, used to exercise the fee-on-transfer guard.
contract MockDirectShortTransferToken is ERC20 {
    constructor(uint256 supply, address recipient) ERC20("Short Transfer Token", "SHORT") {
        _mint(recipient, supply);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        _spendAllowance(from, _msgSender(), value);
        _transfer(from, to, value - 1);
        return true;
    }
}

/// @notice Shared fixture for DirectLaunchStrategy unit tests. Deploys the real v4 PoolManager /
///         PositionManager and the hookless strategy. `launcher` is this test contract,
///         so it can drive `initializeDistribution` directly.
abstract contract DirectLaunchTestBase is Test {
    IPoolManager internal constant POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IPositionManager internal constant POSITION_MANAGER = IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);

    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000 ether;
    int24 internal constant INITIAL_TICK = 122_000;
    /// @dev Lowest aligned initial tick at which the full supply still fits under maxLiquidityPerTick;
    ///      one spacing lower reverts UnrealizableLaunch.
    int24 internal constant LOWEST_REALIZABLE_TICK = -349_200;

    address internal launcher = address(this);
    IPoolManager internal poolManager = POOL_MANAGER;
    IPositionManager internal positionManager = POSITION_MANAGER;
    DirectLaunchStrategy internal strategy;

    function setUp() public virtual {
        deployCodeTo("lib/v4-core/src/PoolManager.sol:PoolManager", abi.encode(address(this)), address(POOL_MANAGER));
        deployCodeTo(
            "lib/v4-periphery/src/PositionManager.sol:PositionManager",
            abi.encode(POOL_MANAGER, address(0), uint256(0), address(0), address(0)),
            address(POSITION_MANAGER)
        );

        strategy = new DirectLaunchStrategy(launcher, POSITION_MANAGER, POOL_MANAGER, INITIAL_TICK);
        vm.deal(address(this), 100_000 ether);
    }

    /// @notice Deploys a strategy with the given tick and the shared collaborators (used by constructor tests).
    function _deployStrategy(int24 initialTick) internal returns (DirectLaunchStrategy) {
        return new DirectLaunchStrategy(launcher, POSITION_MANAGER, POOL_MANAGER, initialTick);
    }

    /// @notice Mints a fresh 1B-supply / 18-decimal token to this contract.
    function _deployToken(uint256 supply) internal returns (MockERC20) {
        return new MockERC20("Direct Token", "DIRECT", supply, address(this));
    }

    /// @notice Approves and launches `token` through the strategy as the launcher.
    function _initialize(IERC20 token, uint256 totalSupply, bytes memory configData) internal {
        token.approve(address(strategy), totalSupply);
        strategy.initializeDistribution(address(token), totalSupply, configData, bytes32(0));
    }

    /// @notice Predicts the BuybackAndBurnPositionRecipient the next launch will deploy.
    function _predictRecipient() internal view returns (address) {
        return vm.computeCreateAddress(address(strategy), vm.getNonce(address(strategy)));
    }

    receive() external payable {}
}
