// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BondingCurveLaunchStrategy} from "../../../../src/strategies/BondingCurveLaunchStrategy.sol";
import {IBondingCurveLaunchHook} from "../../../../src/interfaces/IBondingCurveLaunchHook.sol";
import {DirectLaunchParameters} from "../../../../src/libraries/DirectLaunchParams.sol";
import {MockERC20} from "../../../mocks/MockERC20.sol";

contract MockBondingPositionManager {
    uint256 public nextTokenId = 1;
}

contract BondingCurveLaunchStrategyHarness is BondingCurveLaunchStrategy {
    using PoolIdLibrary for PoolKey;

    address public lastToken;
    uint256 public lastTotalSupply;
    bytes public lastConfigData;
    uint256 public lastBalanceBefore;

    constructor(
        address _launcher,
        IPositionManager _positionManager,
        IPoolManager _poolManager,
        IBondingCurveLaunchHook _launchHook,
        address _dynamicFeeModule,
        int24 _initialTick,
        int24 _graduationTick
    )
        BondingCurveLaunchStrategy(
            _launcher, _positionManager, _poolManager, _launchHook, _dynamicFeeModule, _initialTick, _graduationTick
        )
    {}

    function _launch(address token, uint256 totalSupply, DirectLaunchParameters memory params, uint256 balanceBefore)
        internal
        override
        returns (PoolId poolId, PoolKey memory key, bytes memory)
    {
        lastToken = token;
        lastTotalSupply = totalSupply;
        lastConfigData = abi.encode(params);
        lastBalanceBefore = balanceBefore;

        bool tokenIsCurrency0 = Currency.wrap(token) < Currency.wrap(params.currency);
        key = PoolKey({
            currency0: tokenIsCurrency0 ? Currency.wrap(token) : Currency.wrap(params.currency),
            currency1: tokenIsCurrency0 ? Currency.wrap(params.currency) : Currency.wrap(token),
            fee: params.poolParameters.fee,
            tickSpacing: params.poolParameters.tickSpacing,
            hooks: IHooks(params.poolParameters.hook)
        });
        poolId = key.toId();
        IERC20(token).transfer(address(0xdead), totalSupply);
        return (poolId, key, bytes(""));
    }
}

contract MockBondingSixDecimalToken is ERC20 {
    constructor(uint256 supply, address recipient) ERC20("Six Decimal Token", "SIX") {
        _mint(recipient, supply);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

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

abstract contract BondingCurveLaunchTestBase is Test {
    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000 ether;
    int24 internal constant INITIAL_TICK = 122_000;
    int24 internal constant GRADUATION_TICK = 94_200;

    address internal launcher = address(this);
    IBondingCurveLaunchHook internal launchHook = IBondingCurveLaunchHook(makeAddr("launchHook"));
    address internal dynamicFeeModule = makeAddr("dynamicFeeModule");
    IPoolManager internal poolManager = IPoolManager(makeAddr("poolManager"));

    MockBondingPositionManager internal positionManager;
    BondingCurveLaunchStrategyHarness internal strategyHarness;
    BondingCurveLaunchStrategy internal strategy;

    function setUp() public virtual {
        positionManager = new MockBondingPositionManager();
        strategy = _deployStrategy(INITIAL_TICK, GRADUATION_TICK);
        strategyHarness = BondingCurveLaunchStrategyHarness(payable(address(strategy)));
    }

    function _deployStrategy(int24 initialTick, int24 graduationTick) internal returns (BondingCurveLaunchStrategy) {
        return new BondingCurveLaunchStrategyHarness(
            launcher,
            IPositionManager(address(positionManager)),
            poolManager,
            launchHook,
            dynamicFeeModule,
            initialTick,
            graduationTick
        );
    }

    function _deployToken(uint256 supply) internal returns (MockERC20) {
        return new MockERC20("Bonding Token", "BOND", supply, address(this));
    }

    function _initialize(IERC20 token, uint256 totalSupply, bytes memory configData) internal {
        token.approve(address(strategy), totalSupply);
        strategy.initializeDistribution(address(token), totalSupply, configData, bytes32(uint256(1)));
    }
}
