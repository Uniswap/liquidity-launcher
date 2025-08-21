// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/// @title Plan
/// @notice Represents a plan of actions to be executed in a pool
struct Plan {
    bytes actions;
    bytes[] params;
}
