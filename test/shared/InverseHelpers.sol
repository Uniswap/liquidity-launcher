// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @title InverseHelpers
/// @notice A library for calculating inverses in Q96 fixed-point representation
/// @dev Used in test suite for price conversions and inverse calculations
library InverseHelpers {
    /// @notice The Q96 constant representing 1 in fixed-point notation
    uint256 constant Q96 = 1 << 96;
    uint256 constant Q192 = 1 << 192;

    /// @notice Calculate the inverse of a Q96 fixed-point number using FullMath
    /// @param value The Q96 fixed-point value to invert
    /// @return The inverse in Q96 fixed-point representation
    /// @dev Calculates (1 << 192) / value * (1 << 96) with full 512 bit precision
    function inverseQ96(uint256 value) internal pure returns (uint256) {
        require(value > 0, "InverseHelpers: cannot invert zero");
        return FullMath.mulDiv(Q192, Q96, value);
    }
}
