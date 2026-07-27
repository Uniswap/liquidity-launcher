// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title ICreatorClaimRecipient
/// @notice A claim recipient paying a native-ETH position's native fee share to the creator of the
///         launcher-created token it pairs.
interface ICreatorClaimRecipient {
    /// @notice Thrown when the position's currency0 is not native.
    /// @param tokenId The position token ID.
    error NotNativePosition(uint256 tokenId);

    /// @notice Thrown when the caller is not the creator recorded in currency1's graffiti.
    /// @param tokenId The position token ID.
    /// @param caller The unauthorized caller.
    error NotTokenCreator(uint256 tokenId, address caller);
}
