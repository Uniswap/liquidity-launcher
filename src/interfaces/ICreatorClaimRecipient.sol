// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title ICreatorClaimRecipient
/// @notice A claim recipient paying a native-ETH position's native fee share to the creator of the
///         launcher-created token it pairs, minting them a transferable ERC721 claim right on the
///         first claim.
interface ICreatorClaimRecipient {
    /// @notice Thrown when the position's currency0 is not native.
    /// @param tokenId The position token ID.
    error NotNativePosition(uint256 tokenId);

    /// @notice Thrown when an unminted position's currency1 graffiti does not record the caller.
    /// @param tokenId The position token ID.
    /// @param caller The unauthorized caller.
    error NotTokenCreator(uint256 tokenId, address caller);

    /// @notice Thrown when the caller does not hold a minted position's claim NFT.
    /// @param tokenId The position token ID.
    /// @param caller The unauthorized caller.
    error NotClaimOwner(uint256 tokenId, address caller);
}
