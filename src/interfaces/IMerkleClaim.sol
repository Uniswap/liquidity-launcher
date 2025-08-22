// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IDistributionContract} from "./IDistributionContract.sol";

interface IMerkleClaim is IDistributionContract {
    /// @notice Custom errors for merkle claim functionality
    error ClaimExpired();
    error OnlyOwner();
    error ClaimStillActive();

    /// @notice Emitted when tokens are swept by the owner after endTime
    /// @param owner The address that swept the tokens
    /// @param amount The amount of tokens swept
    event TokensSwept(address indexed owner, uint256 amount);

    /// @notice The ERC20 token being distributed
    /// @return The address of the token contract
    function token() external view returns (address);

    /// @notice The merkle root containing all valid claims
    /// @return The merkle root as bytes32
    function merkleRoot() external view returns (bytes32);

    /// @notice The owner who can sweep tokens after endTime
    /// @return The address of the owner
    function owner() external view returns (address);

    /// @notice The timestamp after which claims expire and tokens can be swept
    /// @return The end timestamp (type(uint256).max = no deadline)
    function endTime() external view returns (uint256);

    /// @notice Check if a specific index has been claimed
    /// @param index The index to check
    /// @return True if the index has been claimed, false otherwise
    function isClaimed(uint256 index) external view returns (bool);

    /// @notice Claim tokens from the merkle distribution
    /// @dev Verifies the merkle proof and transfers tokens to the account
    /// @param index The index of this claim in the merkle tree
    /// @param account The account that will receive the claimed tokens
    /// @param amount The amount of tokens to claim
    /// @param merkleProof Array of merkle proof hashes to verify the claim
    function claim(uint256 index, address account, uint256 amount, bytes32[] calldata merkleProof) external;

    /// @notice Sweep remaining tokens to the owner after endTime
    /// @dev Only callable by owner and only after endTime has passed
    function sweep() external;
}
