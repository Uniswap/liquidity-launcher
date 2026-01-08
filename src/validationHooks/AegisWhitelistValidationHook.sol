// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MerkleProofLib} from "@solady/src/utils/MerkleProofLib.sol";
import {IAegisWhitelistValidationHook} from "../interfaces/IAegisWhitelistValidationHook.sol";

contract AegisWhitelistValidationHook is IAegisWhitelistValidationHook, Ownable {

    uint8 public constant TIER_ONE = 1;
    uint8 public constant TIER_TWO = 2;
    uint8 public constant TIER_THREE = 3;

    mapping(uint8 => bytes32) public rootByTier;
    mapping(uint8 => uint128) public capByTier;
    mapping(address => uint128) public committed;
    mapping(address => uint8) public assignedTier;
    mapping(uint8 => mapping(address => bool)) public manualWhitelist;

    // Initialize tier roots/caps and set the owner for manual whitelist management.
    constructor(
        bytes32 rootTierOne,
        bytes32 rootTierTwo,
        bytes32 rootTierThree,
        uint128 capTierOne,
        uint128 capTierTwo,
        uint128 capTierThree
    ) Ownable() {
        rootByTier[TIER_ONE] = rootTierOne;
        rootByTier[TIER_TWO] = rootTierTwo;
        rootByTier[TIER_THREE] = rootTierThree;

        capByTier[TIER_ONE] = capTierOne;
        capByTier[TIER_TWO] = capTierTwo;
        capByTier[TIER_THREE] = capTierThree;
    }

    // Owner-only toggle for manual whitelist entries by tier.
    function setManualWhitelist(uint8 tier, address account, bool allowed) external onlyOwner {
        manualWhitelist[tier][account] = allowed;
    }

    // Owner-only update for tier Merkle roots.
    function setRootByTier(uint8 tier, bytes32 root) external onlyOwner {
        rootByTier[tier] = root;
    }

    // Validate bids using tiered caps and either manual whitelist or Merkle proof membership.
    function validate(uint256, uint128 amount, address owner, address, bytes calldata hookData) external override {
        // Decode tier + Merkle proof from hook data (encoded off-chain).
        (uint8 tier, bytes32[] memory proof) = abi.decode(hookData, (uint8, bytes32[]));
        // Look up the Merkle root for the provided tier.
        bytes32 root = rootByTier[tier];
        // A zero root means the tier is not configured.
        if (root == bytes32(0)) revert InvalidTier(tier);

        // Skip proof verification if manually whitelisted for this tier.
        if (!manualWhitelist[tier][owner]) {
            // Leaf is the keccak256 of the bidder address.
            bytes32 leaf = keccak256(abi.encodePacked(owner));
            // Validate the Merkle proof against the tier root.
            if (!MerkleProofLib.verify(proof, root, leaf)) revert InvalidProof();
        }

        // Read any previously assigned tier for this owner.
        uint8 existingTier = assignedTier[owner];
        if (existingTier == 0) {
            // First valid bid assigns the tier permanently.
            assignedTier[owner] = tier;
        } else if (existingTier != tier) {
            // Reject attempts to switch tiers after assignment.
            revert TierMismatch(existingTier, tier);
        }

        // Compute the new committed total if this bid is accepted.
        uint256 nextCommitted = uint256(committed[owner]) + amount;
        // Look up the commitment cap for the provided tier.
        uint128 cap = capByTier[tier];
        // Enforce the tier cap.
        if (nextCommitted > cap) revert ExceedsTierCap(tier, nextCommitted, cap);

        // Persist the updated committed amount.
        committed[owner] = uint128(nextCommitted);
    }
}
