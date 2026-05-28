// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {PositionPlanner} from "src/libraries/PositionPlanner.sol";
import {PositionDefinition} from "src/types/PositionPlannerTypes.sol";

library PositionPlannerFuzzHelpers {
    uint24 internal constant MPS = 1e7;

    function boundPositionDefinitions(PositionDefinition[] memory rawDefinitions, int24 currentTick, int24 tickSpacing)
        internal
        pure
        returns (PositionDefinition[] memory definitions)
    {
        uint256 count =
            rawDefinitions.length == 0 ? 1 : _bound(rawDefinitions.length, 1, PositionPlanner.MAX_ADDITIONAL_POSITIONS_PER_PLAN);

        definitions = new PositionDefinition[](count);
        uint24 remainingWeight = MPS;
        for (uint256 i; i < count; i++) {
            PositionDefinition memory raw = rawDefinitions.length == 0
                ? PositionDefinition({offsetLower: int24(0), offsetUpper: int24(0), weight: uint24(0)})
                : rawDefinitions[i];

            uint24 weight;
            if (i == count - 1) {
                weight = remainingWeight;
            } else {
                uint24 positionsLeft = uint24(count - i - 1);
                weight = uint24(_bound(raw.weight, 1, remainingWeight - positionsLeft));
                remainingWeight -= weight;
            }

            (int24 offsetLower, int24 offsetUpper) =
                boundTickOffsets(raw.offsetLower, raw.offsetUpper, currentTick, tickSpacing);
            definitions[i] = PositionDefinition({offsetLower: offsetLower, offsetUpper: offsetUpper, weight: weight});
        }
    }

    function boundTickOffsets(int24 rawLower, int24 rawUpper, int24 currentTick, int24 tickSpacing)
        internal
        pure
        returns (int24 offsetLower, int24 offsetUpper)
    {
        if (rawLower == TickMath.MIN_TICK && rawUpper == TickMath.MAX_TICK) {
            return (rawLower, rawUpper);
        }

        int24 minOffset = TickMath.minUsableTick(tickSpacing) - currentTick;
        int24 maxOffset = TickMath.maxUsableTick(tickSpacing) - currentTick;

        offsetLower = int24(_bound(int256(rawLower), int256(minOffset), int256(maxOffset)));
        offsetUpper = int24(_bound(int256(rawUpper), int256(minOffset), int256(maxOffset)));
        if (offsetLower > offsetUpper) {
            (offsetLower, offsetUpper) = (offsetUpper, offsetLower);
        }
        if (offsetLower == offsetUpper) {
            if (offsetLower > minOffset) offsetLower--;
            else offsetUpper++;
        }
    }

    /// @notice Fuzz the amount0/1 for a given seed, tick lower, tick upper, and tick spacing.
    /// @dev Returns amounts which do not overflow max liquidity per tick and produce non-zero liquidity.
    function fuzzValidAmounts(uint256 seed, int24 currentTick, int24 tickLower, int24 tickUpper, int24 tickSpacing)
        internal
        pure
        returns (uint128 amount0, uint128 amount1)
    {
        uint128 maxLiquidity = Pool.tickSpacingToMaxLiquidityPerTick(tickSpacing);
        amount0 = uint128(
            _bound(
                uint128(uint256(keccak256(abi.encode(seed, 0))) % type(uint128).max),
                SqrtPriceMath.getAmount0Delta(
                    TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(currentTick), 1, true
                ),
                SqrtPriceMath.getAmount0Delta(
                    TickMath.getSqrtPriceAtTick(tickLower),
                    TickMath.getSqrtPriceAtTick(currentTick),
                    maxLiquidity,
                    false
                )
            )
        );
        amount1 = uint128(
            _bound(
                uint128(uint256(keccak256(abi.encode(seed, 1))) % type(uint128).max),
                SqrtPriceMath.getAmount1Delta(
                    TickMath.getSqrtPriceAtTick(tickUpper), TickMath.getSqrtPriceAtTick(currentTick), 1, true
                ),
                SqrtPriceMath.getAmount1Delta(
                    TickMath.getSqrtPriceAtTick(tickUpper),
                    TickMath.getSqrtPriceAtTick(currentTick),
                    maxLiquidity,
                    false
                )
            )
        );

        uint128 liquidity0 = LiquidityAmounts.getLiquidityForAmount0(
            TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(currentTick), amount0
        );
        uint128 liquidity1 = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(currentTick), TickMath.getSqrtPriceAtTick(tickUpper), amount1
        );
        uint128 liquidity = liquidity0 > 0 && liquidity0 < liquidity1 ? liquidity0 : liquidity1;
        if (liquidity == 0) liquidity = 1;

        amount0 = SafeCast.toUint128(
            SqrtPriceMath.getAmount0Delta(
                TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(currentTick), liquidity, true
            )
        );
        amount1 = SafeCast.toUint128(
            SqrtPriceMath.getAmount1Delta(
                TickMath.getSqrtPriceAtTick(currentTick), TickMath.getSqrtPriceAtTick(tickUpper), liquidity, true
            )
        );
    }

    /// @notice Fuzz the tick offsets for a given seed, current tick, and tick spacing.
    function fuzzTickOffsets(uint256 seed, int24 currentTick, int24 tickSpacing) internal pure returns (int24, int24) {
        int24 minOffset = TickMath.minUsableTick(tickSpacing) - currentTick;
        int24 maxOffset = TickMath.maxUsableTick(tickSpacing) - currentTick;
        uint256 absRange = uint256(int256(maxOffset) - int256(minOffset) + 1);

        int24 rawLower = int24(int256(uint256(keccak256(abi.encode(seed, 0))) % absRange) + int256(minOffset));
        int24 rawUpper = int24(int256(uint256(keccak256(abi.encode(seed, 1))) % absRange) + int256(minOffset));
        return boundTickOffsets(rawLower, rawUpper, currentTick, tickSpacing);
    }

    function _bound(uint256 x, uint256 min, uint256 max) private pure returns (uint256 result) {
        require(min <= max, "PositionPlannerFuzzHelpers: max < min");
        if (x >= min && x <= max) return x;

        uint256 size = max - min + 1;
        if (x > max) {
            uint256 rem = (x - max) % size;
            return rem == 0 ? max : min + rem - 1;
        }

        uint256 diff = min - x;
        uint256 remainder = diff % size;
        return remainder == 0 ? min : max - remainder + 1;
    }

    function _bound(int256 x, int256 min, int256 max) private pure returns (int256 result) {
        require(min <= max, "PositionPlannerFuzzHelpers: max < min");
        if (x >= min && x <= max) return x;

        uint256 size = uint256(max - min) + 1;
        if (x > max) {
            uint256 rem = uint256(x - max) % size;
            return rem == 0 ? max : min + int256(rem) - 1;
        }

        uint256 diff = uint256(min - x);
        uint256 remainder = diff % size;
        return remainder == 0 ? min : max - int256(remainder) + 1;
    }
}
