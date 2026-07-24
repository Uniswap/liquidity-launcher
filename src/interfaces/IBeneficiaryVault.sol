// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IBeneficiaryVault
/// @notice A transferable ERC721 claim on a position's attributed LP fees.
/// @dev Fee attribution is permissionless and balance-backed; untracked surplus, including donations,
///      is attributable by the first caller.
interface IBeneficiaryVault {
    /// @notice Thrown when a registration caller does not custody the position in the PositionManager.
    /// @param tokenId The position token ID.
    /// @param sender The caller that failed the custody proof.
    error NotPositionOwner(uint256 tokenId, address sender);

    /// @notice Thrown when this contract is named as its own beneficiary.
    /// @param beneficiary The invalid beneficiary.
    error InvalidBeneficiary(address beneficiary);

    /// @notice Thrown when a caller is not the position's current beneficiary NFT holder.
    /// @param tokenId The position token ID.
    /// @param caller The unauthorized caller.
    error NotBeneficiary(uint256 tokenId, address caller);

    /// @notice Thrown when a fallback is zero or this contract.
    /// @param fallbackRecipient The invalid fallback.
    error InvalidFallback(address fallbackRecipient);

    /// @notice Registers `beneficiary` as the recipient of `tokenId`'s fee stream, minting (or
    ///         re-minting) the transferable beneficiary NFT with the position's tokenId.
    /// @dev Caller MUST own the position in the PositionManager, so registration must happen BEFORE
    ///      transferring the position to a terminal custodian like the FeeSplitter. Re-registration
    ///      replaces the beneficiary; unclaimed credits follow the NFT.
    /// @param tokenId The position whose fee stream is being assigned.
    /// @param beneficiary The receiver of the beneficiary NFT.
    function registerBeneficiary(uint256 tokenId, address beneficiary) external;

    /// @notice The receiver for unregistered positions' native fee shares.
    function nativeFallback() external view returns (address);

    /// @notice The receiver for unregistered positions' token fee shares.
    function tokenFallback() external view returns (address);
}
