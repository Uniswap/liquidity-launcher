// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @title Distribution
/// @notice Represents one distribution instruction: which strategy to use, how many tokens, and any custom data
struct Distribution {
    address strategy;
    uint256 amount;
    bytes configData;
}
