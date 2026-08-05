// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title INativeStrategy
/// @notice Interface for strategies that spend native instead of a distributed token.
interface INativeStrategy {
    /// @notice Run this strategy with the native forwarded in this call.
    /// @param configData Arbitrary, strategy-specific parameters.
    /// @param salt The launcher's per-caller salt, if used by the strategy.
    function initializeWithNative(bytes calldata configData, bytes32 salt) external payable;
}
