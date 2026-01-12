// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IProtocolFeeController
interface IProtocolFeeController {
    /// @notice Returns the protocol fee in basis points, must be less than or equal to the configured
    ///         maximum protocol fee of 1_000 basis points.
    /// @param currency The currency address, address(0) for native
    /// @param amount The amount denoted in currency
    function getProtocolFeeBps(address currency, uint256 amount) external view returns (uint24);
}
