// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Represents one distribution instruction: which strategy to use, how many tokens, and any custom data
struct Distribution {
    address strategy;
    uint256 amount;
    bytes configData;
}
