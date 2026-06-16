// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {PositionPlanner} from "../../../../../src/libraries/PositionPlanner.sol";
import {Position, PositionDefinition, CurrencyAmounts} from "../../../../../src/types/PositionPlannerTypes.sol";
import {PositionPlannerFuzzHelpers} from "test/shared/PositionPlannerFuzzHelpers.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";

contract PositionPlannerHarness {
    function resolve(
        PositionDefinition[] memory definitions,
        uint160 sqrtPriceX96,
        int24 tickSpacing,
        CurrencyAmounts memory currencyAmounts,
        address positionRecipient
    ) external pure returns (Position[] memory, CurrencyAmounts memory) {
        return PositionPlanner.resolve(definitions, sqrtPriceX96, tickSpacing, currencyAmounts, positionRecipient);
    }

    function resolvePosition(
        int24 lowerTick,
        int24 upperTick,
        uint160 sqrtPriceX96,
        uint128 maxLiquidity,
        CurrencyAmounts memory currencyAmounts,
        address recipient
    ) external pure returns (Position memory) {
        return PositionPlanner.resolvePosition(
            PositionPlanner.TickBounds({lowerTick: lowerTick, upperTick: upperTick}),
            sqrtPriceX96,
            maxLiquidity,
            currencyAmounts,
            recipient
        );
    }
}

/// @title PositionPlannerBTTTest
/// @notice BTT tests for PositionPlanner recipient resolution and resolvePosition guards
///
/// resolve
/// ├── given an explicit definition with a non-zero override recipient
/// │   └── it assigns the override recipient to the position
/// ├── given an explicit definition with a zero override recipient
/// │   └── it assigns the default position recipient to the position
/// ├── given multiple definitions with mixed override recipients
/// │   └── it assigns each position its own resolved recipient
/// └── given the implicit full-range fallback
///     └── it assigns the default position recipient
///
/// resolvePosition
/// ├── when tick bounds are invalid
/// │   └── it returns an empty position
/// ├── when liquidity is zero
/// │   └── it returns an empty position
/// ├── when liquidity exceeds the max liquidity
/// │   └── it caps liquidity and backs out amounts from the capped liquidity
/// ├── when liquidity is within the max liquidity
/// │   └── it uses the full derived liquidity
/// └── when a valid position is created
///     └── it assigns the provided recipient
contract PositionPlannerBTTTest is Test {
    PositionPlannerHarness public harness;

    function setUp() public {
        harness = new PositionPlannerHarness();
    }

    /// @notice Builds a full-range definition with the given weight and override recipient.
    function _fullRangeDef(uint24 weight, address overrideRecipient) internal pure returns (PositionDefinition memory) {
        return PositionDefinition({
            offsetLower: TickMath.MIN_TICK,
            offsetUpper: TickMath.MAX_TICK,
            weight: weight,
            overridePositionRecipient: overrideRecipient
        });
    }

    // --- resolve: recipient resolution ---

    function test_Resolve_GivenAnExplicitDefinitionWithANonZeroOverrideRecipient_AssignsTheOverrideRecipient(
        uint256 seed,
        int24 currentTick,
        int24 tickSpacing,
        address overrideRecipient,
        address defaultRecipient
    ) public view {
        // it assigns the override recipient to the position
        vm.assume(overrideRecipient != address(0));
        tickSpacing = int24(bound(tickSpacing, TickMath.MIN_TICK_SPACING, TickMath.MAX_TICK_SPACING));
        currentTick = int24(bound(currentTick, TickMath.MIN_TICK / 2, TickMath.MAX_TICK / 2));
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(currentTick);
        (uint128 amount0, uint128 amount1) = PositionPlannerFuzzHelpers.fuzzValidAmounts(
            seed, currentTick, TickMath.MIN_TICK, TickMath.MAX_TICK, tickSpacing
        );

        PositionDefinition[] memory defs = new PositionDefinition[](1);
        defs[0] = _fullRangeDef(1e7, overrideRecipient);

        (Position[] memory positions,) = harness.resolve(
            defs, sqrtPriceX96, tickSpacing, CurrencyAmounts({amount0: amount0, amount1: amount1}), defaultRecipient
        );

        // positions[0] is the explicit definition, processed in input order
        assertGe(positions.length, 1);
        assertEq(positions[0].recipient, overrideRecipient);
    }

    function test_Resolve_GivenAnExplicitDefinitionWithAZeroOverrideRecipient_AssignsTheDefaultPositionRecipient(
        uint256 seed,
        int24 currentTick,
        int24 tickSpacing,
        address defaultRecipient
    ) public view {
        // it assigns the default position recipient to the position
        vm.assume(defaultRecipient != address(0));
        tickSpacing = int24(bound(tickSpacing, TickMath.MIN_TICK_SPACING, TickMath.MAX_TICK_SPACING));
        currentTick = int24(bound(currentTick, TickMath.MIN_TICK / 2, TickMath.MAX_TICK / 2));
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(currentTick);
        (uint128 amount0, uint128 amount1) = PositionPlannerFuzzHelpers.fuzzValidAmounts(
            seed, currentTick, TickMath.MIN_TICK, TickMath.MAX_TICK, tickSpacing
        );

        PositionDefinition[] memory defs = new PositionDefinition[](1);
        defs[0] = _fullRangeDef(1e7, address(0));

        (Position[] memory positions,) = harness.resolve(
            defs, sqrtPriceX96, tickSpacing, CurrencyAmounts({amount0: amount0, amount1: amount1}), defaultRecipient
        );

        assertGe(positions.length, 1);
        assertEq(positions[0].recipient, defaultRecipient);
    }

    function test_Resolve_GivenMultipleDefinitionsWithMixedOverrideRecipients_AssignsEachItsResolvedRecipient(
        address overrideRecipient,
        address defaultRecipient
    ) public view {
        // it assigns each position its own resolved recipient
        vm.assume(overrideRecipient != address(0) && defaultRecipient != address(0));
        vm.assume(overrideRecipient != defaultRecipient);

        // Fixed, valid geometry that reliably creates both explicit positions (mirrors
        // test_resolve_keepsDefinitionsInInputOrder); the recipients are the fuzzed dimension.
        // A global per-tick liquidity cap means position survival is not guaranteed under arbitrary
        // geometry, so geometry is pinned and only recipients vary.
        int24 tickSpacing = 10;
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(0);

        PositionDefinition[] memory defs = new PositionDefinition[](2);
        // [0] resolves to the override recipient, [1] falls through to the default recipient
        defs[0] = _fullRangeDef(5e6, overrideRecipient);
        defs[1] =
            PositionDefinition({offsetLower: -20, offsetUpper: 20, weight: 5e6, overridePositionRecipient: address(0)});

        (Position[] memory positions,) = harness.resolve(
            defs, sqrtPriceX96, tickSpacing, CurrencyAmounts({amount0: 100e18, amount1: 100e18}), defaultRecipient
        );

        // input order is preserved
        assertGe(positions.length, 2);
        assertEq(positions[0].recipient, overrideRecipient);
        assertEq(positions[1].recipient, defaultRecipient);
    }

    function test_Resolve_GivenTheImplicitFullRangeFallback_AssignsTheDefaultPositionRecipient(
        uint256 seed,
        int24 currentTick,
        int24 tickSpacing,
        address defaultRecipient
    ) public view {
        // it assigns the default position recipient
        vm.assume(defaultRecipient != address(0));
        tickSpacing = int24(bound(tickSpacing, TickMath.MIN_TICK_SPACING, TickMath.MAX_TICK_SPACING));
        currentTick = int24(bound(currentTick, TickMath.MIN_TICK / 2, TickMath.MAX_TICK / 2));
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(currentTick);
        (uint128 amount0, uint128 amount1) = PositionPlannerFuzzHelpers.fuzzValidAmounts(
            seed, currentTick, TickMath.MIN_TICK, TickMath.MAX_TICK, tickSpacing
        );

        // No explicit definitions: only the implicit full-range fallback is created.
        PositionDefinition[] memory defs = new PositionDefinition[](0);

        (Position[] memory positions,) = harness.resolve(
            defs, sqrtPriceX96, tickSpacing, CurrencyAmounts({amount0: amount0, amount1: amount1}), defaultRecipient
        );

        assertEq(positions.length, 1);
        assertEq(positions[0].recipient, defaultRecipient);
    }

    // --- resolvePosition: guards ---

    function test_ResolvePosition_WhenTickBoundsAreInvalid_ReturnsAnEmptyPosition(
        int24 lowerTick,
        int24 upperTick,
        int24 currentTick,
        uint128 maxLiquidity,
        uint128 amount0,
        uint128 amount1,
        address recipient
    ) public view {
        // it returns an empty position
        lowerTick = int24(bound(lowerTick, TickMath.MIN_TICK, TickMath.MAX_TICK));
        // upperTick <= lowerTick makes the bounds invalid (isValid requires lowerTick < upperTick)
        upperTick = int24(bound(upperTick, TickMath.MIN_TICK, lowerTick));
        currentTick = int24(bound(currentTick, TickMath.MIN_TICK, TickMath.MAX_TICK));

        Position memory position = harness.resolvePosition(
            lowerTick,
            upperTick,
            TickMath.getSqrtPriceAtTick(currentTick),
            maxLiquidity,
            CurrencyAmounts({amount0: amount0, amount1: amount1}),
            recipient
        );

        assertEq(position.liquidity, 0);
        assertEq(position.amount0, 0);
        assertEq(position.amount1, 0);
        // recipient is not assigned on the early return
        assertEq(position.recipient, address(0));
    }

    function test_ResolvePosition_WhenLiquidityIsZero_ReturnsAnEmptyPosition(
        int24 currentTick,
        int24 lowerTick,
        int24 upperTick,
        uint128 maxLiquidity,
        uint128 amount1,
        address recipient
    ) public view {
        // it returns an empty position
        // Range sits entirely above the current tick, so the position needs only currency0;
        // supplying zero currency0 yields zero liquidity regardless of currency1.
        currentTick = int24(bound(currentTick, TickMath.MIN_TICK, TickMath.MAX_TICK - 2));
        lowerTick = int24(bound(lowerTick, currentTick + 1, TickMath.MAX_TICK - 1));
        upperTick = int24(bound(upperTick, lowerTick + 1, TickMath.MAX_TICK));

        Position memory position = harness.resolvePosition(
            lowerTick,
            upperTick,
            TickMath.getSqrtPriceAtTick(currentTick),
            maxLiquidity,
            CurrencyAmounts({amount0: 0, amount1: amount1}),
            recipient
        );

        assertEq(position.liquidity, 0);
        assertEq(position.amount0, 0);
        assertEq(position.amount1, 0);
        assertEq(position.recipient, address(0));
    }

    function test_ResolvePosition_WhenLiquidityExceedsTheMaxLiquidity_CapsLiquidityAndBacksOutAmountsFromTheCappedLiquidity(
        int24 currentTick,
        uint128 maxLiquidity,
        address recipient
    ) public view {
        // it caps liquidity and backs out amounts from the capped liquidity
        // A 2-tick range fed the maximum possible amounts derives liquidity far above any uint64 value,
        // so bounding the cap to uint64 guarantees the cap branch fires across the whole tick range.
        maxLiquidity = uint128(bound(maxLiquidity, 1, type(uint64).max));
        currentTick = int24(bound(currentTick, TickMath.MIN_TICK / 2, TickMath.MAX_TICK / 2));

        int24 lowerTick = currentTick - 1;
        int24 upperTick = currentTick + 1;
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(currentTick);
        uint128 hugeAmount = type(uint128).max;

        Position memory position = harness.resolvePosition(
            lowerTick,
            upperTick,
            sqrtPriceX96,
            maxLiquidity,
            CurrencyAmounts({amount0: hugeAmount, amount1: hugeAmount}),
            recipient
        );

        // liquidity is clamped to the max
        assertEq(position.liquidity, maxLiquidity);
        // amounts are derived from the capped liquidity (not the uncapped, larger derived liquidity).
        // Current tick is strictly inside (lowerTick, upperTick), so both legs are non-zero (rounded up).
        assertEq(
            position.amount0,
            SqrtPriceMath.getAmount0Delta(sqrtPriceX96, TickMath.getSqrtPriceAtTick(upperTick), maxLiquidity, true)
        );
        assertEq(
            position.amount1,
            SqrtPriceMath.getAmount1Delta(TickMath.getSqrtPriceAtTick(lowerTick), sqrtPriceX96, maxLiquidity, true)
        );
        assertEq(position.recipient, recipient);
    }

    function test_ResolvePosition_WhenAValidPositionIsCreated_AssignsTheProvidedRecipient(
        uint256 seed,
        int24 currentTick,
        int24 tickSpacing,
        address recipient
    ) public view {
        // it assigns the provided recipient
        tickSpacing = int24(bound(tickSpacing, TickMath.MIN_TICK_SPACING, TickMath.MAX_TICK_SPACING));
        currentTick = int24(bound(currentTick, TickMath.MIN_TICK / 2, TickMath.MAX_TICK / 2));
        int24 lowerTick = TickMath.minUsableTick(tickSpacing);
        int24 upperTick = TickMath.maxUsableTick(tickSpacing);
        (uint128 amount0, uint128 amount1) = PositionPlannerFuzzHelpers.fuzzValidAmounts(
            seed, currentTick, TickMath.MIN_TICK, TickMath.MAX_TICK, tickSpacing
        );

        Position memory position = harness.resolvePosition(
            lowerTick,
            upperTick,
            TickMath.getSqrtPriceAtTick(currentTick),
            type(uint128).max,
            CurrencyAmounts({amount0: amount0, amount1: amount1}),
            recipient
        );

        assertGt(position.liquidity, 0);
        assertEq(position.tickLower, lowerTick);
        assertEq(position.tickUpper, upperTick);
        assertEq(position.recipient, recipient);
    }
}
