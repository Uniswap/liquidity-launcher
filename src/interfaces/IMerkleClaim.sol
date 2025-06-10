// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IMerkleClaim {
    /// @notice Custom errors for merkle claim functionality
    error DistributionDoesNotExist();
    error DistributionExpired();
    error AlreadyClaimed();
    error ExceedsTotalAllocation();
    error InvalidMerkleProof();
    error OnlyCreator();
    error DistributionNotExpired();
    error NoTokensToSweep();
    error OnlyLauncher();

    /// @notice Emitted when a merkle root is set for a token
    event MerkleRootSet(IERC20 indexed token, bytes32 merkleRoot);
    
    /// @notice Emitted when a new distribution is created
    event DistributionCreated(
        uint256 indexed distributionId,
        IERC20 indexed token,
        address indexed creator,
        bytes32 merkleRoot,
        uint256 totalAmount,
        uint256 deadline
    );

    /// @notice Emitted when tokens are claimed
    event TokensClaimed(
        uint256 indexed distributionId,
        IERC20 indexed token, 
        uint256 index, 
        address indexed account, 
        uint256 amount
    );

    /// @notice Emitted when unclaimed tokens are swept by the creator
    event TokensSwept(
        uint256 indexed distributionId,
        IERC20 indexed token,
        address indexed creator,
        uint256 amount
    );

    /// @notice Check if a distribution exists
    /// @param distributionId The distribution ID to check
    /// @return exists Whether the distribution exists
    function distributionExists(uint256 distributionId) external view returns (bool);

    /// @notice Check if a specific index has been claimed for a distribution
    /// @param distributionId The distribution ID
    /// @param index The index to check
    /// @return claimed Whether the index has been claimed
    function isClaimed(uint256 distributionId, uint256 index) external view returns (bool);

    /// @notice Claim tokens from a merkle distribution
    /// @dev Verifies the merkle proof against the stored root for the distribution and transfers tokens to the account
    /// @param distributionId The distribution ID to claim from
    /// @param index The index of this claim in the merkle tree
    /// @param account The account that will receive the claimed tokens
    /// @param amount The amount of tokens to claim
    /// @param merkleProof Array of merkle proof hashes to verify the claim
    function claim(uint256 distributionId, uint256 index, address account, uint256 amount, bytes32[] calldata merkleProof) external;

    /// @notice Sweep unclaimed tokens back to the creator after deadline
    /// @dev Only the creator can call this function and only after the deadline has passed
    /// @param distributionId The distribution ID to sweep
    function sweep(uint256 distributionId) external;
}