// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IBeneficiaryVault
/// @notice A transferable ERC721 claim on a position's attributed LP fees.
/// @dev Fee credit is permissionless and balance-backed. For hook-enabled tokens, an attacker can re-enter
///      between a pusher's transfer and its callback and attribute that in-flight balance to another position.
///      Standard tokens, including UERC20, have no such window. Any untracked surplus, including donations,
///      is attributable by the first caller; donation flushing is intentional.
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
    /// @dev Authorized by custody: only the position's current owner in the PositionManager may
    ///      register, so registration must happen BEFORE the position is transferred to a terminal
    ///      custodian like the FeeSplitter — afterwards it is final. A re-registration by the current
    ///      custodian replaces a stale beneficiary, and unclaimed credits follow the NFT. The vault
    ///      cannot verify it is wired into the fee source's splits — registering with an unwired vault
    ///      earns nothing, so integrators must check the wiring themselves.
    /// @param tokenId The position whose fee stream is being assigned.
    /// @param beneficiary The receiver of the beneficiary NFT.
    function registerBeneficiary(uint256 tokenId, address beneficiary) external;

    /// @notice The receiver for unregistered positions' native fee shares.
    function nativeFallback() external view returns (address);

    /// @notice The receiver for unregistered positions' token fee shares.
    function tokenFallback() external view returns (address);
}
