// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IValidationHook} from "continuous-clearing-auction/src/interfaces/IValidationHook.sol";

/// @title IAegisWhitelistValidationHook
/// @notice Interface for the tiered whitelist validation hook used by the auction.
interface IAegisWhitelistValidationHook is IValidationHook {
    /// @notice Thrown when a provided tier does not exist.
    /// @param tier The tier id passed in hook data.
    error InvalidTier(uint8 tier);

    /// @notice Thrown when a Merkle proof does not validate against the tier root.
    error InvalidProof();

    /// @notice Thrown when a bidder attempts to use a different tier after assignment.
    /// @param expected The tier previously assigned to the bidder.
    /// @param provided The tier supplied in the hook data.
    error TierMismatch(uint8 expected, uint8 provided);

    /// @notice Thrown when a bid would exceed the tier cap.
    /// @param tier The tier id used for the cap.
    /// @param attempted The total committed amount after the bid.
    /// @param cap The maximum allowed for the tier.
    error ExceedsTierCap(uint8 tier, uint256 attempted, uint256 cap);

    /// @notice Returns the Merkle root for a tier.
    /// @param tier The tier id.
    /// @return root The Merkle root for the tier.
    function rootByTier(uint8 tier) external view returns (bytes32 root);

    /// @notice Returns the commitment cap for a tier.
    /// @param tier The tier id.
    /// @return cap The maximum commitment in wei for the tier.
    function capByTier(uint8 tier) external view returns (uint128 cap);

    /// @notice Returns the total committed amount for a bidder.
    /// @param account The bidder address.
    /// @return amount The committed amount in wei.
    function committed(address account) external view returns (uint128 amount);

    /// @notice Returns the tier assigned to a bidder after their first valid bid.
    /// @param account The bidder address.
    /// @return tier The assigned tier id.
    function assignedTier(address account) external view returns (uint8 tier);

    /// @notice Returns true if an address is manually whitelisted for a tier.
    /// @param tier The tier id.
    /// @param account The address to check.
    /// @return allowed Whether the address is manually allowed for the tier.
    function manualWhitelist(uint8 tier, address account) external view returns (bool allowed);

    /// @notice Add an address to the manual whitelist for a tier.
    /// @param tier The tier id.
    /// @param account The address to whitelist.
    function setManualWhitelist(uint8 tier, address account, bool allowed) external;

    /// @notice Update the Merkle root for a tier.
    /// @param tier The tier id.
    /// @param root The new Merkle root.
    function setRootByTier(uint8 tier, bytes32 root) external;
}
