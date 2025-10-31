// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @title TickCalculations
/// @notice Library for tick calculations
library TickCalculations {
    /// @notice Derives max liquidity per tick from given tick spacing
    /// @dev Taken directly from Pool.sol
    /// @param tickSpacing The amount of required tick separation, realized in multiples of `tickSpacing` (cannot be 0)
    ///     e.g., a tickSpacing of 3 requires ticks to be initialized every 3rd tick i.e., ..., -6, -3, 0, 3, 6, ...
    /// @return result The max liquidity per tick
    function tickSpacingToMaxLiquidityPerTick(int24 tickSpacing) internal pure returns (uint128 result) {
        int24 MAX_TICK = TickMath.MAX_TICK;
        int24 MIN_TICK = TickMath.MIN_TICK;
        assembly ("memory-safe") {
            tickSpacing := signextend(2, tickSpacing)
            let minTick := sub(sdiv(MIN_TICK, tickSpacing), slt(smod(MIN_TICK, tickSpacing), 0))
            let maxTick := sdiv(MAX_TICK, tickSpacing)
            let numTicks := add(sub(maxTick, minTick), 1)
            result := div(sub(shl(128, 1), 1), numTicks)
        }
    }

    /// @notice Rounds down to the nearest tick spacing if needed
    /// @param tick The tick to round down
    /// @param tickSpacing The tick spacing to round down to (cannot be 0)
    /// @return The rounded down tick
    function tickFloor(int24 tick, int24 tickSpacing) internal pure returns (int24) {
        unchecked {
            int24 remainder = tick % tickSpacing;
            return remainder >= 0 ? tick - remainder : tick - remainder - tickSpacing;
        }
    }

    /// @notice Rounds up to the next tick spacing
    /// @param tick The tick to round up
    /// @param tickSpacing The tick spacing to round up to (cannot be 0)
    /// @return The rounded up tick
    function tickStrictCeil(int24 tick, int24 tickSpacing) internal pure returns (int24) {
        unchecked {
            int24 remainder = tick % tickSpacing;
            return remainder >= 0 ? tick + tickSpacing - remainder : tick - remainder;
        }
    }
}
