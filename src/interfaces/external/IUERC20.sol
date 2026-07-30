// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IUERC20
/// @notice Minimal interface for launcher-created UERC20 tokens
interface IUERC20 {
    /// @notice The creator graffiti set at deployment; bytes32(0) when unset
    function graffiti() external view returns (bytes32);
}
