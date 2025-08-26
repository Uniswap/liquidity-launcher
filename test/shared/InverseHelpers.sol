// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @title InverseHelpers
/// @notice A library for calculating inverses in Q96 fixed-point representation
/// @dev Used in test suite for price conversions and inverse calculations
library InverseHelpers {
    /// @notice The Q96 constant representing 1 in fixed-point notation
    uint256 constant Q96 = 1 << 96;

    /// @notice Calculate the inverse of a Q96 fixed-point number
    /// @param value The Q96 fixed-point value to invert
    /// @return The inverse in Q96 fixed-point representation
    /// @dev Calculates (1 << 96)^2 / value
    function inverseQ96(uint256 value) internal pure returns (uint256) {
        require(value > 0, "InverseHelpers: cannot invert zero");
        return FullMath.mulDiv(Q96, Q96, value);
    }

    /// @notice Calculate the inverse of a price in Q96 format
    /// @param priceQ96 The price in Q96 format to invert
    /// @return The inverted price in Q96 format
    /// @dev Alias for inverseQ96, used for clarity when dealing with prices
    function invertPrice(uint256 priceQ96) internal pure returns (uint256) {
        return inverseQ96(priceQ96);
    }
}
