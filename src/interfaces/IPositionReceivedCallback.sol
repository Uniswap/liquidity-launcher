// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IPositionReceivedCallback
/// @notice Callback for a FeeSplitter split recipient that opts into targeted position deposit notifications.
interface IPositionReceivedCallback {
    /// @notice Called for the recipient's targeted PositionCallbackData entry during a position deposit.
    /// @dev Reverts bubble so registration and the position transfer either both complete or both fail.
    /// @param tokenId The deposited position token ID.
    /// @param from The address that transferred the position.
    /// @param data The entry's PositionCallbackData payload.
    function onPositionReceived(uint256 tokenId, address from, bytes calldata data) external;
}
