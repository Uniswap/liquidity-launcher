// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PositionPlanner} from "../../../../../src/libraries/PositionPlanner.sol";
import {PositionDefinition} from "../../../../../src/types/PositionPlannerTypes.sol";

contract ValidateSingleSidedHarness {
    function validateSingleSided(
        PositionDefinition[] memory definitions,
        uint160 sqrtPriceX96,
        int24 tickSpacing,
        bool tokenIsCurrency0
    ) external pure {
        PositionPlanner.validateSingleSided(definitions, sqrtPriceX96, tickSpacing, tokenIsCurrency0);
    }
}

/// @title ValidateSingleSidedTest
/// @notice BTT tests for PositionPlanner.validateSingleSided
///
/// validateSingleSided
/// ├── when token is currency0
/// │   ├── when every resolved range is at or above the price
/// │   │   └── it passes
/// │   ├── when a resolved range's lower tick is below the price
/// │   │   └── it reverts with PositionNotSingleSided
/// │   └── when a resolved range spans the price
/// │       └── it reverts with PositionNotSingleSided
/// ├── when token is currency1
/// │   ├── when every resolved range is at or below the price
/// │   │   └── it passes
/// │   ├── when a resolved range's upper tick is above the price
/// │   │   └── it reverts with PositionNotSingleSided
/// │   └── when a resolved range spans the price
/// │       └── it reverts with PositionNotSingleSided
/// ├── when a definition uses the full-range sentinel
/// │   └── it reverts with PositionNotSingleSided
/// └── when the price is between initialized ticks
///     └── it rejects a range whose lower tick equals the price's tick
contract ValidateSingleSidedTest is Test {
    ValidateSingleSidedHarness harness;

    function setUp() public {
        harness = new ValidateSingleSidedHarness();
    }

    function _definition(int24 offsetLower, int24 offsetUpper) internal pure returns (PositionDefinition[] memory) {
        PositionDefinition[] memory definitions = new PositionDefinition[](1);
        definitions[0] = PositionDefinition({
            offsetLower: offsetLower, offsetUpper: offsetUpper, weight: 1e7, overridePositionRecipient: address(0)
        });
        return definitions;
    }

    /// @notice Bounds fuzz inputs to a tick spacing and a spacing-aligned current tick with headroom on both sides
    function _boundAligned(int24 tickSpacing, int24 alignedTick, uint24 width)
        internal
        pure
        returns (int24, int24, int24)
    {
        tickSpacing = int24(bound(tickSpacing, 1, 1000));
        int24 maxUsable = TickMath.maxUsableTick(tickSpacing);
        // Keep at least `width` spacings of room above and below the current tick.
        int24 boundedWidth = int24(uint24(bound(width, 1, 100)));
        int24 maxMultiplier = maxUsable / tickSpacing - boundedWidth;
        alignedTick = int24(bound(alignedTick, -maxMultiplier, maxMultiplier)) * tickSpacing;
        return (tickSpacing, alignedTick, boundedWidth);
    }

    function test_fuzz_passesWhenToken0RangesAreAtOrAbovePrice(int24 tickSpacing, int24 alignedTick, uint24 width)
        public
        view
    {
        int24 boundedWidth;
        (tickSpacing, alignedTick, boundedWidth) = _boundAligned(tickSpacing, alignedTick, width);
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(alignedTick);

        // Lower bound exactly at the price's aligned tick is token-side inclusive.
        harness.validateSingleSided(_definition(0, boundedWidth * tickSpacing), sqrtPriceX96, tickSpacing, true);
    }

    function test_fuzz_revertsWhenToken0RangeIsBelowPrice(int24 tickSpacing, int24 alignedTick, uint24 width) public {
        int24 boundedWidth;
        (tickSpacing, alignedTick, boundedWidth) = _boundAligned(tickSpacing, alignedTick, width);
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(alignedTick);

        int24 offsetLower = -boundedWidth * tickSpacing;
        vm.expectRevert(
            abi.encodeWithSelector(
                PositionPlanner.PositionNotSingleSided.selector, alignedTick + offsetLower, alignedTick
            )
        );
        harness.validateSingleSided(_definition(offsetLower, 0), sqrtPriceX96, tickSpacing, true);
    }

    function test_fuzz_revertsWhenToken0RangeSpansPrice(int24 tickSpacing, int24 alignedTick, uint24 width) public {
        int24 boundedWidth;
        (tickSpacing, alignedTick, boundedWidth) = _boundAligned(tickSpacing, alignedTick, width);
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(alignedTick);

        int24 offset = boundedWidth * tickSpacing;
        vm.expectRevert(
            abi.encodeWithSelector(
                PositionPlanner.PositionNotSingleSided.selector, alignedTick - offset, alignedTick + offset
            )
        );
        harness.validateSingleSided(_definition(-offset, offset), sqrtPriceX96, tickSpacing, true);
    }

    function test_fuzz_passesWhenToken1RangesAreAtOrBelowPrice(int24 tickSpacing, int24 alignedTick, uint24 width)
        public
        view
    {
        int24 boundedWidth;
        (tickSpacing, alignedTick, boundedWidth) = _boundAligned(tickSpacing, alignedTick, width);
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(alignedTick);

        // Upper bound exactly at the price's aligned tick is token-side inclusive.
        harness.validateSingleSided(_definition(-boundedWidth * tickSpacing, 0), sqrtPriceX96, tickSpacing, false);
    }

    function test_fuzz_revertsWhenToken1RangeIsAbovePrice(int24 tickSpacing, int24 alignedTick, uint24 width) public {
        int24 boundedWidth;
        (tickSpacing, alignedTick, boundedWidth) = _boundAligned(tickSpacing, alignedTick, width);
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(alignedTick);

        int24 offsetUpper = boundedWidth * tickSpacing;
        vm.expectRevert(
            abi.encodeWithSelector(
                PositionPlanner.PositionNotSingleSided.selector, alignedTick, alignedTick + offsetUpper
            )
        );
        harness.validateSingleSided(_definition(0, offsetUpper), sqrtPriceX96, tickSpacing, false);
    }

    function test_fuzz_revertsWhenToken1RangeSpansPrice(int24 tickSpacing, int24 alignedTick, uint24 width) public {
        int24 boundedWidth;
        (tickSpacing, alignedTick, boundedWidth) = _boundAligned(tickSpacing, alignedTick, width);
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(alignedTick);

        int24 offset = boundedWidth * tickSpacing;
        vm.expectRevert(
            abi.encodeWithSelector(
                PositionPlanner.PositionNotSingleSided.selector, alignedTick - offset, alignedTick + offset
            )
        );
        harness.validateSingleSided(_definition(-offset, offset), sqrtPriceX96, tickSpacing, false);
    }

    function test_fuzz_revertsOnFullRangeSentinel(int24 tickSpacing, bool tokenIsCurrency0) public {
        tickSpacing = int24(bound(tickSpacing, 1, 1000));
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(0);

        vm.expectRevert(
            abi.encodeWithSelector(
                PositionPlanner.PositionNotSingleSided.selector,
                TickMath.minUsableTick(tickSpacing),
                TickMath.maxUsableTick(tickSpacing)
            )
        );
        harness.validateSingleSided(
            _definition(TickMath.MIN_TICK, TickMath.MAX_TICK), sqrtPriceX96, tickSpacing, tokenIsCurrency0
        );
    }

    function test_revertsWhenPriceIsBetweenTicksAndLowerTickEqualsPriceTick() public {
        // Price strictly between tick 0 and tick 1: a token0 range starting at the floored tick 0 spans the price.
        uint160 sqrtPriceX96 = (TickMath.getSqrtPriceAtTick(0) + TickMath.getSqrtPriceAtTick(1)) / 2;

        vm.expectRevert(abi.encodeWithSelector(PositionPlanner.PositionNotSingleSided.selector, 0, 10));
        harness.validateSingleSided(_definition(0, 10), sqrtPriceX96, 1, true);
    }
}
