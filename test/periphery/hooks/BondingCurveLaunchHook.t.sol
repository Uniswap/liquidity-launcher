// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HookTestBase} from "./HookTestBase.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {LaunchConfig} from "../../../src/interfaces/ILaunchHook.sol";
import {
    IBondingCurveLaunchHook,
    BondingCurveHookConfig,
    BondingCurvePhase
} from "../../../src/interfaces/IBondingCurveLaunchHook.sol";
import {BondingCurveLaunchHook} from "../../../src/periphery/hooks/BondingCurveLaunchHook.sol";

contract BondingCurveLaunchHookNoValidation is BondingCurveLaunchHook {
    constructor(IPoolManager _poolManager, address _authorized) BondingCurveLaunchHook(_poolManager, _authorized) {}

    function validateHookAddress(BaseHook) internal pure override {}
}

/// @title BondingCurveLaunchHookTest
/// @notice BTT tests for BondingCurveLaunchHook
///
/// setLaunchConfig
/// ├── when specialized configuration is missing or inconsistent
/// │   └── it reverts with InvalidBondingCurveConfig
/// └── when specialized configuration is valid
///     └── it enters the seeding phase
///
/// beforeAddLiquidity
/// ├── while seeding
/// │   ├── when the position does not match the curve
/// │   │   └── it reverts with InvalidCurvePosition
/// │   └── when the position matches the curve
/// │       └── it enters the active phase
/// ├── while active
/// │   └── it rejects additional liquidity
/// └── while graduating
///     └── it accepts one full-range position and enters the graduated phase
///
/// beforeSwap
/// ├── before graduation
/// │   ├── when a buy can cross the terminal price
/// │   │   └── it reverts with InvalidBuyPriceLimit
/// │   └── when the pool is at the terminal price
/// │       └── it reverts with GraduationPending
/// └── after graduation
///     └── it permits swaps and returns the base fee
///
/// beginGraduation
/// ├── when called by an address other than the configured manager
/// │   └── it reverts with InvalidGraduationManager
/// ├── when the terminal price has not been reached
/// │   └── it reverts with GraduationNotReady
/// └── when called by the manager at the terminal price
///     └── it enters the graduating phase
contract BondingCurveLaunchHookTest is HookTestBase {
    int24 internal constant TICK_SPACING = 200;
    int24 internal constant INITIAL_TICK = 1_000;
    int24 internal constant GRADUATION_TICK = -1_000;
    bytes4 internal constant EXTSLOAD_SELECTOR = bytes4(keccak256("extsload(bytes32)"));

    BondingCurveLaunchHook internal hook;
    address internal manager = makeAddr("manager");

    function setUp() public {
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG;
        address hookAddress = _computeHookAddress(flags);
        BondingCurveLaunchHookNoValidation implementation =
            new BondingCurveLaunchHookNoValidation(IPoolManager(poolManager), strategy);
        vm.etch(hookAddress, address(implementation).code);
        hook = BondingCurveLaunchHook(hookAddress);
    }

    function test_setLaunchConfig_revertsWhenHookConfigIsMissing() public {
        PoolKey memory key = _poolKey();
        LaunchConfig memory config = _config(bytes(""));

        vm.prank(strategy);
        vm.expectRevert(IBondingCurveLaunchHook.InvalidBondingCurveConfig.selector);
        hook.setLaunchConfig(key.toId(), config);
    }

    function test_setLaunchConfig_revertsWhenTerminalPriceDoesNotMatchRange() public {
        BondingCurveHookConfig memory hookConfig = _hookConfig();
        hookConfig.graduationSqrtPriceX96 = TickMath.getSqrtPriceAtTick(GRADUATION_TICK + TICK_SPACING);

        vm.prank(strategy);
        vm.expectRevert(IBondingCurveLaunchHook.InvalidBondingCurveConfig.selector);
        hook.setLaunchConfig(_poolKey().toId(), _config(abi.encode(hookConfig)));
    }

    function test_setLaunchConfig_entersSeedingPhase() public {
        PoolId poolId = _setConfig();

        assertEq(uint256(hook.bondingCurvePhase(poolId)), uint256(BondingCurvePhase.Seeding));
        BondingCurveHookConfig memory stored = hook.bondingCurveConfig(poolId);
        assertEq(stored.manager, manager);
        assertEq(stored.graduationSqrtPriceX96, TickMath.getSqrtPriceAtTick(GRADUATION_TICK));
        assertEq(stored.curveTickLower, GRADUATION_TICK);
        assertEq(stored.curveTickUpper, INITIAL_TICK);
    }

    function test_beforeInitialize_revertsWhenInitialPriceDoesNotMatchRange() public {
        PoolKey memory key = _poolKey();
        _setConfig();

        vm.prank(poolManager);
        vm.expectRevert(IBondingCurveLaunchHook.InvalidBondingCurveConfig.selector);
        hook.beforeInitialize(strategy, key, TickMath.getSqrtPriceAtTick(INITIAL_TICK - TICK_SPACING));
    }

    function test_beforeAddLiquidity_revertsWhenSeedPositionDoesNotMatchCurve() public {
        PoolKey memory key = _poolKey();
        _setConfig();
        ModifyLiquidityParams memory params = _curvePosition();
        params.tickLower += TICK_SPACING;

        vm.prank(poolManager);
        vm.expectRevert(IBondingCurveLaunchHook.InvalidCurvePosition.selector);
        hook.beforeAddLiquidity(address(this), key, params, bytes(""));
    }

    function test_beforeAddLiquidity_activatesExactCurvePositionAndRejectsAdditionalLiquidity() public {
        PoolKey memory key = _poolKey();
        PoolId poolId = _setConfig();
        ModifyLiquidityParams memory params = _curvePosition();

        vm.prank(poolManager);
        hook.beforeAddLiquidity(address(this), key, params, bytes(""));
        assertEq(uint256(hook.bondingCurvePhase(poolId)), uint256(BondingCurvePhase.Active));

        vm.prank(poolManager);
        vm.expectRevert(
            abi.encodeWithSelector(IBondingCurveLaunchHook.InvalidBondingCurvePhase.selector, BondingCurvePhase.Active)
        );
        hook.beforeAddLiquidity(address(this), key, params, bytes(""));
    }

    function test_beforeSwap_revertsWhenBuyLimitCrossesGraduation() public {
        PoolKey memory key = _activate();
        _mockPrice(TickMath.getSqrtPriceAtTick(INITIAL_TICK));
        uint160 invalidLimit = TickMath.getSqrtPriceAtTick(GRADUATION_TICK - TICK_SPACING);

        vm.prank(poolManager);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBondingCurveLaunchHook.InvalidBuyPriceLimit.selector,
                invalidLimit,
                TickMath.getSqrtPriceAtTick(GRADUATION_TICK)
            )
        );
        hook.beforeSwap(address(this), key, _swapParams(true, invalidLimit), bytes(""));
    }

    function test_beforeSwap_revertsAtGraduationPrice() public {
        PoolKey memory key = _activate();
        _mockPrice(TickMath.getSqrtPriceAtTick(GRADUATION_TICK));

        vm.prank(poolManager);
        vm.expectRevert(IBondingCurveLaunchHook.GraduationPending.selector);
        hook.beforeSwap(address(this), key, _swapParams(false, TickMath.getSqrtPriceAtTick(INITIAL_TICK)), bytes(""));
    }

    function test_beginGraduation_revertsWhenCallerIsNotManager() public {
        PoolKey memory key = _activate();

        vm.expectRevert(
            abi.encodeWithSelector(IBondingCurveLaunchHook.InvalidGraduationManager.selector, address(this), manager)
        );
        hook.beginGraduation(key);
    }

    function test_beginGraduation_revertsBeforeTerminalPrice() public {
        PoolKey memory key = _activate();
        _mockPrice(TickMath.getSqrtPriceAtTick(INITIAL_TICK));

        vm.prank(manager);
        vm.expectRevert(IBondingCurveLaunchHook.GraduationNotReady.selector);
        hook.beginGraduation(key);
    }

    function test_beginGraduation_acceptsFullRangePositionAndReopensSwaps() public {
        PoolKey memory key = _activate();
        PoolId poolId = key.toId();
        _mockPrice(TickMath.getSqrtPriceAtTick(GRADUATION_TICK));

        vm.prank(manager);
        hook.beginGraduation(key);
        assertEq(uint256(hook.bondingCurvePhase(poolId)), uint256(BondingCurvePhase.Graduating));

        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: TickMath.minUsableTick(TICK_SPACING),
            tickUpper: TickMath.maxUsableTick(TICK_SPACING),
            liquidityDelta: 1,
            salt: bytes32(0)
        });
        vm.prank(poolManager);
        hook.beforeAddLiquidity(address(this), key, params, bytes(""));
        assertEq(uint256(hook.bondingCurvePhase(poolId)), uint256(BondingCurvePhase.Graduated));

        vm.prank(poolManager);
        (,, uint24 fee) = hook.beforeSwap(
            address(this), key, _swapParams(true, TickMath.getSqrtPriceAtTick(GRADUATION_TICK)), bytes("")
        );
        assertEq(fee, LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function _poolKey() private view returns (PoolKey memory key) {
        key = _defaultPoolKey(address(hook));
        key.fee = LPFeeLibrary.DYNAMIC_FEE_FLAG;
        key.tickSpacing = TICK_SPACING;
    }

    function _hookConfig() private view returns (BondingCurveHookConfig memory) {
        return BondingCurveHookConfig({
            manager: manager,
            graduationSqrtPriceX96: TickMath.getSqrtPriceAtTick(GRADUATION_TICK),
            curveTickLower: GRADUATION_TICK,
            curveTickUpper: INITIAL_TICK
        });
    }

    function _config(bytes memory hookConfig) private pure returns (LaunchConfig memory) {
        return LaunchConfig({
            swapStartBlock: 0,
            windowEndBlock: 0,
            baseFee: 0,
            tokenIsCurrency0: false,
            module: address(0),
            moduleConfig: bytes(""),
            hookConfig: hookConfig
        });
    }

    function _setConfig() private returns (PoolId poolId) {
        poolId = _poolKey().toId();
        vm.prank(strategy);
        hook.setLaunchConfig(poolId, _config(abi.encode(_hookConfig())));
    }

    function _curvePosition() private pure returns (ModifyLiquidityParams memory) {
        return ModifyLiquidityParams({
            tickLower: GRADUATION_TICK, tickUpper: INITIAL_TICK, liquidityDelta: 1, salt: bytes32(0)
        });
    }

    function _activate() private returns (PoolKey memory key) {
        key = _poolKey();
        _setConfig();
        vm.prank(poolManager);
        hook.beforeAddLiquidity(address(this), key, _curvePosition(), bytes(""));
    }

    function _swapParams(bool zeroForOne, uint160 sqrtPriceLimitX96) private pure returns (SwapParams memory) {
        return SwapParams({zeroForOne: zeroForOne, amountSpecified: -1 ether, sqrtPriceLimitX96: sqrtPriceLimitX96});
    }

    function _mockPrice(uint160 sqrtPriceX96) private {
        vm.mockCall(poolManager, abi.encodeWithSelector(EXTSLOAD_SELECTOR), abi.encode(bytes32(uint256(sqrtPriceX96))));
    }
}
