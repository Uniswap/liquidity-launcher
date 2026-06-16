// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title TickCalculations
/// @notice Library for tick calculations
library TickCalculations {
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

    /// @notice Rounds up to the nearest tick spacing, preserving exact multiples
    /// @param tick The tick to round up
    /// @param tickSpacing The tick spacing to round up to (cannot be 0)
    /// @return The rounded up tick
    function tickCeil(int24 tick, int24 tickSpacing) internal pure returns (int24) {
        int24 floored = tickFloor(tick, tickSpacing);
        return floored == tick ? tick : floored + tickSpacing;
    }
}
