// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Multicall} from "@openzeppelin/contracts/utils/Multicall.sol";
import {IMerkleClaim} from "../interfaces/IMerkleClaim.sol";
import {IDistributionContract} from "../interfaces/IDistributionContract.sol";
import {IDistributionStrategy} from "../interfaces/IDistributionStrategy.sol";
import {TransientStorage} from "../libraries/TransientStorage.sol";

/// @title MerkleClaim
/// @notice A gas-efficient merkle tree-based token distribution contract
/// @dev This contract handles multiple token distributions using merkle proofs. Each distribution is assigned 
/// a unique ID and can have its own token, merkle root, deadline, and creator. The contract uses bitmap storage
/// for tracking claims and transient storage for secure token receipt verification.
contract MerkleClaim is IMerkleClaim, IDistributionContract, IDistributionStrategy, Multicall {
    using SafeERC20 for IERC20;

    /// @notice The address of the launcher contract that can initialize distributions
    address public immutable launcher;

    /// @notice Counter for distribution IDs, starts at 1 (0 = non-existent)
    uint256 public nextDistributionId = 1;

    /// @notice Mapping from distribution ID to Distribution struct
    mapping(uint256 => Distribution) private distributions;

    /// @notice Mapping from distribution ID to claimed bitmap
    /// @dev Each uint256 can track 256 claim statuses as bits
    mapping(uint256 => mapping(uint256 => uint256)) public claimedBitmap;

    /// @dev Transient storage slots
    uint256 private constant SLOT_BALANCE_BEFORE = 0x01;
    uint256 private constant SLOT_DISTRIBUTION_ID = 0x02;

    /// @notice Constructor to set the launcher address
    /// @param _launcher The address of the launcher contract
    constructor(address _launcher) {
        if (_launcher == address(0)) revert ZeroAddress();
        launcher = _launcher;
    }

    /// @notice Get distribution details
    /// @param distributionId The distribution ID to query
    /// @return The distribution struct
    /// @dev Reverts if the distribution does not exist
    function getDistribution(uint256 distributionId) public view returns (Distribution memory) {
        if (distributionId == 0 || distributionId >= nextDistributionId) {
            revert DistributionDoesNotExist();
        }
        return distributions[distributionId];
    }

    /// @inheritdoc IDistributionStrategy
    function initializeDistribution(address _token, uint256 amount, bytes calldata configData)
        external
        returns (IDistributionContract distributionContract)
    {
        IERC20 token = IERC20(_token);
        
        // Tstore current balance for verification in onTokensReceived
        uint256 currentBalance = token.balanceOf(address(this));
        TransientStorage.tstore(SLOT_BALANCE_BEFORE, currentBalance);
        TransientStorage.tstore(SLOT_DISTRIBUTION_ID, nextDistributionId);
        
        // Decode the merkle root, deadline, and creator from configData
        (bytes32 merkleRoot, uint256 deadline, address creator) = abi.decode(configData, (bytes32, uint256, address));
        
        // Create new distribution with unique ID (clearer pattern)
        uint256 distributionId = nextDistributionId;
        nextDistributionId++;
        
        distributions[distributionId] = Distribution({
            token: token,
            merkleRoot: merkleRoot,
            creator: creator,  // Now uses the actual creator, not the launcher
            totalAmount: amount,
            claimedAmount: 0,
            deadline: deadline,
            active: false  // Distribution starts as inactive until tokens are received
        });
        
        emit DistributionCreated(distributionId, token, creator, merkleRoot, amount, deadline);
        
        return IDistributionContract(address(this));
    }

    /// @inheritdoc IDistributionContract
    function onTokensReceived(address _token, uint256 amount) external {
        // Tload previous balance and distribution ID from transient storage
        uint256 previousBalance = TransientStorage.tload(SLOT_BALANCE_BEFORE);
        uint256 distributionId = TransientStorage.tload(SLOT_DISTRIBUTION_ID);
        
        // Verify the contract actually received the expected tokens
        IERC20 token = IERC20(_token);
        uint256 currentBalance = token.balanceOf(address(this));
        if (currentBalance < previousBalance + amount) revert InsufficientTokenBalance();
        
        // Activate the distribution now that tokens have been received
        distributions[distributionId].active = true;
    }

    /// @notice Check if a specific index has been claimed for a distribution
    /// @param distributionId The distribution ID
    /// @param index The index to check
    /// @return claimed Whether the index has been claimed
    function isClaimed(uint256 distributionId, uint256 index) public view returns (bool) {
        uint256 wordIndex = index / 256;
        uint256 bitIndex = index % 256;
        uint256 word = claimedBitmap[distributionId][wordIndex];
        uint256 mask = (1 << bitIndex);
        return word & mask == mask;
    }
    
    /// @notice Mark an index as claimed for a distribution
    /// @param distributionId The distribution ID
    /// @param index The index to mark as claimed
    function _setClaimed(uint256 distributionId, uint256 index) private {
        uint256 wordIndex = index / 256;
        uint256 bitIndex = index % 256;
        claimedBitmap[distributionId][wordIndex] |= (1 << bitIndex);
    }

    /// @notice Claim tokens from a merkle distribution
    /// @dev Verifies the merkle proof against the stored root for the distribution and transfers tokens to the account
    /// @param distributionId The distribution ID to claim from
    /// @param index The index of this claim in the merkle tree
    /// @param account The account that will receive the claimed tokens
    /// @param amount The amount of tokens to claim
    /// @param merkleProof Array of merkle proof hashes to verify the claim
    function claim(uint256 distributionId, uint256 index, address account, uint256 amount, bytes32[] calldata merkleProof) external {
        Distribution memory dist = getDistribution(distributionId);
        
        if (!dist.active) revert DistributionNotActive();
        if (block.timestamp > dist.deadline) revert DistributionExpired();
        if (isClaimed(distributionId, index)) revert AlreadyClaimed();
        if (dist.claimedAmount + amount > dist.totalAmount) revert ExceedsTotalAllocation();
        
        // Verify merkle proof
        bytes32 leaf = keccak256(abi.encodePacked(index, account, amount));
        if (!MerkleProof.verify(merkleProof, dist.merkleRoot, leaf)) revert InvalidMerkleProof();
        
        // Update claimed amount and mark index as claimed
        distributions[distributionId].claimedAmount += amount;
        _setClaimed(distributionId, index);
        
        // Transfer tokens to account
        dist.token.safeTransfer(account, amount);

        emit TokensClaimed(distributionId, dist.token, index, account, amount);
    }

    /// @notice Sweep unclaimed tokens back to the creator after deadline
    /// @dev Only the creator can call this function and only after the deadline has passed
    /// @param distributionId The distribution ID to sweep
    function sweep(uint256 distributionId) external {
        Distribution memory dist = getDistribution(distributionId);
        
        if (msg.sender != dist.creator) revert OnlyCreator();
        if (block.timestamp <= dist.deadline) revert DistributionNotExpired();
        
        // Calculate unclaimed amount
        uint256 unclaimedAmount = dist.totalAmount - dist.claimedAmount;
        if (unclaimedAmount == 0) revert NoTokensToSweep();
        
        dist.token.safeTransfer(dist.creator, unclaimedAmount);

        emit TokensSwept(distributionId, dist.token, dist.creator, unclaimedAmount);
    }
}