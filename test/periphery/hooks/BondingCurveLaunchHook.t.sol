// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HookTestBase} from "./HookTestBase.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
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
    constructor(IPoolManager _poolManager, IPositionManager _positionManager, address _authorized)
        BondingCurveLaunchHook(_poolManager, _positionManager, _authorized)
    {}

    function validateHookAddress(BaseHook) internal pure override {}
}

/// @title BondingCurveLaunchHookTest
/// @notice BTT tests for BondingCurveLaunchHook
///
/// constructor
/// └── when the PositionManager is zero
///     └── it reverts with ZeroAddress
///
/// setLaunchConfig
/// ├── when specialized configuration is missing or inconsistent
/// │   └── it reverts with InvalidBondingCurveConfig
/// └── when specialized configuration is valid
///     └── it enters the seeding phase
///
/// beforeAddLiquidity
/// ├── while seeding
/// │   ├── when the caller is not the configured PositionManager
/// │   │   └── it reverts with InvalidPositionManager
/// │   ├── when the position does not match the curve
/// │   │   └── it reverts with InvalidCurvePosition
/// │   ├── when the hook does not own the minted NFT
/// │   │   └── it reverts with InvalidCurvePositionOwner
/// │   └── when the position matches the curve
/// │       ├── it records the hook-owned curve NFT
/// │       └── it enters the active phase
/// ├── while active
/// │   └── it rejects additional liquidity
/// └── while graduating
///     └── it accepts one full-range position and enters the graduated phase
///
/// beforeSwap
/// ├── before graduation
/// │   ├── when an exact-input buy can cross the terminal price
/// │   │   └── it permits the swap for atomic graduation
/// │   └── when an exact-output buy exceeds the remaining curve
/// │       └── it reverts with ExactOutputExceedsCurve
/// └── after graduation
///     └── it permits swaps and returns the base fee
contract BondingCurveLaunchHookTest is HookTestBase {
    int24 internal constant TICK_SPACING = 200;
    int24 internal constant INITIAL_TICK = 1_000;
    int24 internal constant GRADUATION_TICK = -1_000;
    bytes4 internal constant EXTSLOAD_SELECTOR = bytes4(keccak256("extsload(bytes32)"));

    BondingCurveLaunchHook internal hook;
    address internal positionManager = makeAddr("positionManager");
    address internal finalPositionRecipient = makeAddr("finalPositionRecipient");

    function setUp() public {
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
            | Hooks.AFTER_SWAP_FLAG;
        address hookAddress = _computeHookAddress(flags);
        BondingCurveLaunchHookNoValidation implementation = new BondingCurveLaunchHookNoValidation(
            IPoolManager(poolManager), IPositionManager(positionManager), strategy
        );
        vm.etch(hookAddress, address(implementation).code);
        hook = BondingCurveLaunchHook(hookAddress);
    }

    function test_constructor_revertsWhenPositionManagerIsZero() public {
        vm.expectRevert(IBondingCurveLaunchHook.ZeroAddress.selector);
        new BondingCurveLaunchHookNoValidation(IPoolManager(poolManager), IPositionManager(address(0)), strategy);
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
        assertEq(stored.reserveTokenAmount, 20 ether);
        assertEq(stored.finalPositionRecipient, finalPositionRecipient);
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

    function test_beforeAddLiquidity_revertsWhenSeedCallerIsNotPositionManager() public {
        PoolKey memory key = _poolKey();
        _setConfig();

        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(IBondingCurveLaunchHook.InvalidPositionManager.selector, address(this)));
        hook.beforeAddLiquidity(address(this), key, _curvePosition(), bytes(""));
    }

    function test_beforeAddLiquidity_revertsWhenHookDoesNotOwnSeedPosition() public {
        PoolKey memory key = _poolKey();
        _setConfig();
        _mockCurvePosition(1, address(this));

        vm.prank(poolManager);
        vm.expectRevert(IBondingCurveLaunchHook.InvalidCurvePositionOwner.selector);
        hook.beforeAddLiquidity(positionManager, key, _curvePosition(), bytes(""));
    }

    function test_beforeAddLiquidity_activatesExactCurvePositionAndRejectsAdditionalLiquidity() public {
        PoolKey memory key = _poolKey();
        PoolId poolId = _setConfig();
        ModifyLiquidityParams memory params = _curvePosition();
        _mockCurvePosition(1, address(hook));

        vm.prank(poolManager);
        hook.beforeAddLiquidity(positionManager, key, params, bytes(""));
        assertEq(hook.curveTokenId(poolId), 1);
        assertEq(uint256(hook.bondingCurvePhase(poolId)), uint256(BondingCurvePhase.Active));

        vm.prank(poolManager);
        vm.expectRevert(
            abi.encodeWithSelector(IBondingCurveLaunchHook.InvalidBondingCurvePhase.selector, BondingCurvePhase.Active)
        );
        hook.beforeAddLiquidity(address(this), key, params, bytes(""));
    }

    function test_beforeSwap_permitsExactInputBuyLimitBeyondGraduation() public {
        PoolKey memory key = _activate();
        _mockPrice(TickMath.getSqrtPriceAtTick(INITIAL_TICK));
        uint160 broadLimit = TickMath.getSqrtPriceAtTick(GRADUATION_TICK - TICK_SPACING);

        vm.prank(poolManager);
        hook.beforeSwap(address(this), key, _swapParams(true, -1 ether, broadLimit), bytes(""));
    }

    function test_beforeSwap_revertsWhenExactOutputExceedsRemainingCurve() public {
        PoolKey memory key = _activate();
        _mockPoolState(TickMath.getSqrtPriceAtTick(INITIAL_TICK), 1 ether);

        vm.prank(poolManager);
        vm.expectPartialRevert(IBondingCurveLaunchHook.ExactOutputExceedsCurve.selector);
        hook.beforeSwap(
            address(this),
            key,
            _swapParams(true, 1 ether, TickMath.getSqrtPriceAtTick(GRADUATION_TICK - TICK_SPACING)),
            bytes("")
        );
    }

    function _poolKey() private view returns (PoolKey memory key) {
        key = _defaultPoolKey(address(hook));
        key.fee = LPFeeLibrary.DYNAMIC_FEE_FLAG;
        key.tickSpacing = TICK_SPACING;
    }

    function _hookConfig() private view returns (BondingCurveHookConfig memory) {
        return BondingCurveHookConfig({
            reserveTokenAmount: 20 ether,
            finalPositionRecipient: finalPositionRecipient,
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
        _mockCurvePosition(1, address(hook));
        vm.prank(poolManager);
        hook.beforeAddLiquidity(positionManager, key, _curvePosition(), bytes(""));
    }

    function _swapParams(bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96)
        private
        pure
        returns (SwapParams memory)
    {
        return SwapParams({
            zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: sqrtPriceLimitX96
        });
    }

    function _mockPrice(uint160 sqrtPriceX96) private {
        vm.mockCall(poolManager, abi.encodeWithSelector(EXTSLOAD_SELECTOR), abi.encode(bytes32(uint256(sqrtPriceX96))));
    }

    function _mockPoolState(uint160 sqrtPriceX96, uint128 liquidity) private {
        PoolId poolId = _poolKey().toId();
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(poolId), bytes32(uint256(6))));
        vm.mockCall(
            poolManager,
            abi.encodeWithSelector(EXTSLOAD_SELECTOR, stateSlot),
            abi.encode(bytes32(uint256(sqrtPriceX96)))
        );
        vm.mockCall(
            poolManager,
            abi.encodeWithSelector(EXTSLOAD_SELECTOR, bytes32(uint256(stateSlot) + 3)),
            abi.encode(bytes32(uint256(liquidity)))
        );
    }

    function _mockCurvePosition(uint256 tokenId, address owner) private {
        vm.mockCall(
            positionManager, abi.encodeWithSelector(IPositionManager.nextTokenId.selector), abi.encode(tokenId + 1)
        );
        vm.mockCall(positionManager, abi.encodeWithSelector(IERC721.ownerOf.selector, tokenId), abi.encode(owner));
    }
}
