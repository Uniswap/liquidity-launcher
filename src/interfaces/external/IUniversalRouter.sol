// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IUniversalRouter
/// @notice The single entry point of the Universal Router that a strategy needs
interface IUniversalRouter {
    /// @notice Executes encoded commands along with provided inputs
    /// @param commands A set of concatenated commands, each 1 byte in length
    /// @param inputs An array of byte strings containing abi encoded inputs for each command
    /// @param deadline The deadline by which the transaction must be executed
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}
