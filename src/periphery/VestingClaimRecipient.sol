// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IClaimableRecipient} from "../interfaces/IClaimableRecipient.sol";
import {BaseClaimRecipient} from "./BaseClaimRecipient.sol";
import {BlockNumberish} from "@uniswap/blocknumberish/src/BlockNumberish.sol";

/// @title VestingClaimRecipient
/// @notice Contract which claims amounts from sources and releases them over time
/// @dev Supports claiming from multiple sources but attributes all amounts to the canonical tokenId on PositionManager
/// @dev Positions are onboarded by transferring a beneficiary NFT in, or by attributing amounts directly through
///      `onAmountsReceived`. Neither is gated, so the per-tokenId release cap bounds one position's rate, not the
///      contract's aggregate rate across positions.
contract VestingClaimRecipient is BaseClaimRecipient, BlockNumberish, IERC721Receiver {
    /// @notice Thrown when a source reports less than the caller's required amounts
    error InsufficientAmounts();

    /// @notice Thrown when the pinned recipient is zero or this contract
    /// @param recipient The invalid recipient
    error InvalidRecipient(IClaimableRecipient recipient);

    /// @notice The maximum currency0 amount releasable per block, per tokenId
    uint128 public immutable maxCurrency0PerBlock;

    /// @notice The maximum currency1 amount releasable per block, per tokenId
    uint128 public immutable maxCurrency1PerBlock;

    /// @notice The receiver of every release, fixed at deploy
    IClaimableRecipient public immutable recipient;

    /// @notice The block number when the last claim was made for a given tokenId, 0 until the first claim
    mapping(uint256 tokenId => uint256 lastClaimed) public lastClaimed;

    /// @notice Emitted on the first claim for a tokenId, when its vesting clock starts
    event VestingStarted(uint256 indexed tokenId, uint256 startBlock);

    constructor(
        IPositionManager _positionManager,
        uint128 _maxCurrency0PerBlock,
        uint128 _maxCurrency1PerBlock,
        IClaimableRecipient _recipient
    ) BaseClaimRecipient(_positionManager) {
        if (address(_recipient) == address(0) || address(_recipient) == address(this)) {
            revert InvalidRecipient(_recipient);
        }
        maxCurrency0PerBlock = _maxCurrency0PerBlock;
        maxCurrency1PerBlock = _maxCurrency1PerBlock;
        recipient = _recipient;
    }

    /// @notice Claims fees from a source for a given tokenId and accounts them to the canonical pool associated with the tokenId from the PositionManager
    /// @dev Only attributes to the canonical tokenId on PositionManager.
    ///      Source contracts MUST ensure that their internal tokenId accounting is 1:1 with the V4 LP NFT id, otherwise amounts received here will be lost.
    ///      Sources MUST pay out the full amount they report from `amounts`, so `currency1` MUST be a standard token that does not take a fee on transfer.
    function claimFor(
        IClaimableRecipient source,
        uint256 tokenId,
        uint128 minCurrency0Amount,
        uint128 minCurrency1Amount
    ) external nonReentrant {
        (uint128 currency0Amount, uint128 currency1Amount) = source.amounts(tokenId);
        // If the amounts are insufficient, revert
        if (currency0Amount < minCurrency0Amount || currency1Amount < minCurrency1Amount) revert InsufficientAmounts();
        // Claim the entire amount possible
        source.claim(tokenId, currency0Amount, currency1Amount);
        // Account the amount to the canonical pool associated with the tokenId from the PositionManager
        onAmountsReceived(tokenId, currency0Amount, currency1Amount);
    }

    /// @inheritdoc IERC721Receiver
    /// @dev Accepts beneficiary NFTs so positions can be onboarded with `safeTransferFrom` as well as `transferFrom`
    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @inheritdoc BaseClaimRecipient
    /// @notice Override to set a maximum cap on the amount of fees that can be claimed for a given tokenId in a time period
    function _beforeClaimTransfer(uint256 _tokenId, Currency, Currency, uint256 _available0, uint256 _available1)
        internal
        override
        returns (address, uint256, address, uint256)
    {
        uint256 last = lastClaimed[_tokenId];
        uint256 blockNumber = _getBlockNumberish();
        // The first claim only starts the clock. An unset entry is not block zero, so measuring against it
        // would release the whole attributed balance at once.
        if (last == 0) {
            lastClaimed[_tokenId] = blockNumber;
            emit VestingStarted(_tokenId, blockNumber);
            return (address(recipient), 0, address(recipient), 0);
        }

        // Cap available amounts at the max per block for the given currency since last claim
        uint256 blocksPassed = blockNumber - last;
        // Don't reset the last claimed block if no blocks have passed
        if (blocksPassed == 0) return (address(recipient), 0, address(recipient), 0);
        lastClaimed[_tokenId] = blockNumber;

        return (
            address(recipient),
            FixedPointMathLib.min(_available0, maxCurrency0PerBlock * blocksPassed),
            address(recipient),
            FixedPointMathLib.min(_available1, maxCurrency1PerBlock * blocksPassed)
        );
    }

    /// @inheritdoc BaseClaimRecipient
    /// @notice Calls `onAmountsReceived` on the recipient to register the transferred amounts
    function _afterClaim(PoolKey memory, uint256 _tokenId, uint256 _toSend0, uint256 _toSend1) internal override {
        recipient.onAmountsReceived(_tokenId, _toSend0, _toSend1);
    }
}
