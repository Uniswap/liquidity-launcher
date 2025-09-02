// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Distribution
/// @notice Represents one distribution instruction: which strategy to use, how many tokens, and any custom data
struct Distribution {
    address strategy;
    uint128 amount;
    bytes configData;
}
