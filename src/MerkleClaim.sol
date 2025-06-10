// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Multicall} from "@openzeppelin/contracts/utils/Multicall.sol";
import {IMerkleClaim} from "./interfaces/IMerkleClaim.sol";
import {IDistributionContract} from "./interfaces/IDistributionContract.sol";
import {IDistributionStrategy} from "./interfaces/IDistributionStrategy.sol";

contract MerkleClaim is IMerkleClaim, IDistributionContract, IDistributionStrategy, Multicall {
    using SafeERC20 for IERC20;

    error OnlyLauncher();

    /// @notice Structure representing a token distribution
    struct Distribution {
        IERC20 token;           // Token being distributed
        bytes32 merkleRoot;     // Merkle root for this distribution
        address creator;        // Address that created this distribution
        uint256 totalAmount;    // Total amount of tokens allocated
        uint256 claimedAmount;  // Total amount of tokens claimed so far
        uint256 deadline;       // Timestamp when distribution expires (leftover can be swept by creator after)
    }

    /// @notice The address of the launcher contract that can initialize distributions
    address public immutable launcher;

    /// @notice Counter for distribution IDs, starts at 1 (0 = non-existent)
    uint256 public nextDistributionId = 1;

    /// @notice Mapping from distribution ID to Distribution struct
    mapping(uint256 => Distribution) public distributions;

    /// @notice Mapping from distribution ID to claimed bitmap
    /// @dev Each uint256 can track 256 claim statuses as bits
    mapping(uint256 => mapping(uint256 => uint256)) public claimedBitmap;

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

    /// @notice Restricts access to only the launcher contract
    modifier onlyLauncher() {
        if (msg.sender != launcher) revert OnlyLauncher();
        _;
    }

    /// @notice Constructor to set the launcher address
    /// @param _launcher The address of the launcher contract
    constructor(address _launcher) {
        if (_launcher == address(0)) revert ZeroAddress();
        launcher = _launcher;
    }

    /// @notice Check if a distribution exists
    /// @param distributionId The distribution ID to check
    /// @return exists Whether the distribution exists
    function distributionExists(uint256 distributionId) public view returns (bool) {
        return distributionId != 0 && distributionId < nextDistributionId;
    }

    /// @inheritdoc IDistributionStrategy
    function initializeDistribution(address _token, uint256 amount, bytes calldata configData)
        external
        onlyLauncher
        returns (IDistributionContract distributionContract)
    {
        IERC20 token = IERC20(_token);
        
        // Tstore current balance and expected amount for verification
        uint256 currentBalance = token.balanceOf(address(this));
        assembly {
            // Store expected amount and balance before transfer for onTokensReceived verification
            tstore(0x01, amount)                          // Slot 1: expected amount
            tstore(0x02, currentBalance)                  // Slot 2: balance before transfer
        }
        
        // Decode the merkle root, deadline, and creator from configData
        (bytes32 merkleRoot, uint256 deadline, address creator) = abi.decode(configData, (bytes32, uint256, address));
        if (creator == address(0)) revert ZeroAddress();
        
        // Create new distribution with unique ID (clearer pattern)
        uint256 distributionId = nextDistributionId;
        nextDistributionId++;
        
        distributions[distributionId] = Distribution({
            token: token,
            merkleRoot: merkleRoot,
            creator: creator,  // Now uses the actual creator, not the launcher
            totalAmount: amount,
            claimedAmount: 0,
            deadline: deadline
        });
        
        emit DistributionCreated(distributionId, token, creator, merkleRoot, amount, deadline);
        
        return IDistributionContract(address(this));
    }

    /// @inheritdoc IDistributionContract
    function onTokensReceived(address _token, uint256 amount) external onlyLauncher {
        // Tload expected values set in initializeDistribution
        uint256 expectedAmount;
        uint256 previousBalance;
        
        assembly {
            expectedAmount := tload(0x01)     // Load expected amount
            previousBalance := tload(0x02)    // Load balance before transfer
        }
        
        // Verify the amount matches what was initialized
        if (amount != expectedAmount) revert AmountMismatch();
        
        // Verify the contract actually received the expected tokens
        IERC20 token = IERC20(_token);
        uint256 currentBalance = token.balanceOf(address(this));
        if (currentBalance < previousBalance + expectedAmount) revert InsufficientTokenBalance();
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
        if (!distributionExists(distributionId)) revert DistributionDoesNotExist();
        
        Distribution storage dist = distributions[distributionId];
        if (block.timestamp > dist.deadline) revert DistributionExpired();
        if (isClaimed(distributionId, index)) revert AlreadyClaimed();
        if (dist.claimedAmount + amount > dist.totalAmount) revert ExceedsTotalAllocation();
        
        // Verify merkle proof
        bytes32 leaf = keccak256(abi.encodePacked(index, account, amount));
        if (!MerkleProof.verify(merkleProof, dist.merkleRoot, leaf)) revert InvalidMerkleProof();
        
        // Update claimed amount and mark index as claimed
        dist.claimedAmount += amount;
        _setClaimed(distributionId, index);
        
        emit TokensClaimed(distributionId, dist.token, index, account, amount);
        
        // Transfer tokens to account
        dist.token.safeTransfer(account, amount);
    }

    /// @notice Sweep unclaimed tokens back to the creator after deadline
    /// @dev Only the creator can call this function and only after the deadline has passed
    /// @param distributionId The distribution ID to sweep
    function sweep(uint256 distributionId) external {
        if (!distributionExists(distributionId)) revert DistributionDoesNotExist();
        
        Distribution storage dist = distributions[distributionId];
        if (msg.sender != dist.creator) revert OnlyCreator();
        if (block.timestamp <= dist.deadline) revert DistributionNotExpired();
        
        // Calculate unclaimed amount
        uint256 unclaimedAmount = dist.totalAmount - dist.claimedAmount;
        if (unclaimedAmount == 0) revert NoTokensToSweep();
        
        emit TokensSwept(distributionId, dist.token, dist.creator, unclaimedAmount);
        
        dist.token.safeTransfer(dist.creator, unclaimedAmount);
    }
}