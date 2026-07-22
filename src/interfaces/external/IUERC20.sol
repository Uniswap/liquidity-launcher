// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Minimal view of a UERC20 token (github.com/Uniswap/uerc20-factory).
/// @dev Only the surface needed to attribute fees; `creator` is an immutable set at token deployment.
interface IUERC20 {
    function creator() external view returns (address);
    function graffiti() external view returns (bytes32);
}
