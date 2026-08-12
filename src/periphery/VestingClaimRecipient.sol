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
/// @dev The vesting speed is chain specific and dependent on the block time.
/// @dev Positions are onboarded by transferring a beneficiary NFT in, or by attributing amounts directly through
///      `onAmountsReceived`. Neither is gated, so the per-tokenId release cap bounds one position's rate, not the
///      contract's aggregate rate across positions.
contract VestingClaimRecipient is BaseClaimRecipient, BlockNumberish, IERC721Receiver {
    /// @notice Thrown when the pinned recipient is zero or this contract
    /// @param recipient The invalid recipient
    error InvalidRecipient(IClaimableRecipient recipient);

    /// @notice Thrown when a source reports less than the caller's required amounts
    error InsufficientAmounts();

    /// @notice Thrown when a source resolves positions against a different position manager
    /// @param positionManager The incompatible position manager
    /// @param expectedPositionManager The expected position manager
    error InvalidPositionManager(IPositionManager positionManager, IPositionManager expectedPositionManager);

    /// @notice The maximum currency0 amount releasable per block, per tokenId
    uint128 public immutable maxCurrency0PerBlock;

    /// @notice The maximum currency1 amount releasable per block, per tokenId
    uint128 public immutable maxCurrency1PerBlock;

    /// @notice The receiver of every release, fixed at deploy
    IClaimableRecipient public immutable recipient;

    /// @notice The block number when the last claim was made for a given tokenId, 0 until the vesting clock starts
    mapping(uint256 tokenId => uint256 lastClaimed) public lastClaimed;

    /// @notice Emitted on the first claim for a tokenId, when its vesting clock starts
    event VestingStarted(uint256 indexed tokenId, uint256 startBlock);

    constructor(
        IPositionManager _positionManager,
        uint128 _maxCurrency0PerBlock,
        uint128 _maxCurrency1PerBlock,
        IClaimableRecipient _recipient
    ) BaseClaimRecipient(_positionManager) {
        if (
            address(_recipient) == address(0) || address(_recipient) == address(this)
                || _recipient.positionManager() != _positionManager
        ) {
            revert InvalidRecipient(_recipient);
        }
        maxCurrency0PerBlock = _maxCurrency0PerBlock;
        maxCurrency1PerBlock = _maxCurrency1PerBlock;
        recipient = _recipient;
    }

    /// @inheritdoc IERC721Receiver
    /// @dev Accepts beneficiary NFTs so positions can be onboarded with `safeTransferFrom` as well as `transferFrom`
    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice Claims a source's attributed amounts for `_tokenId` and re-attributes them here, against the
    ///         canonical pool the position manager resolves for that same token ID
    /// @dev Sources MUST keep their own token ID accounting 1:1 with the v4 LP NFT id, otherwise amounts
    ///      received here are lost. Sources MUST also pay out the full amount they report from `amounts`, so
    ///      `currency1` MUST be a standard token that does not take a fee on transfer.
    /// @param _source The source to claim from
    /// @param _tokenId The token ID of the position
    /// @param _minCurrency0Amount The minimum acceptable currency0 amount
    /// @param _minCurrency1Amount The minimum acceptable currency1 amount
    function claimFrom(
        IClaimableRecipient _source,
        uint256 _tokenId,
        uint128 _minCurrency0Amount,
        uint128 _minCurrency1Amount
    ) external nonReentrant {
        if (_source.positionManager() != positionManager) {
            revert InvalidPositionManager(_source.positionManager(), positionManager);
        }

        (uint128 currency0Amount, uint128 currency1Amount) = _source.amounts(_tokenId);
        if (currency0Amount < _minCurrency0Amount || currency1Amount < _minCurrency1Amount) {
            revert InsufficientAmounts();
        }
        // claim everything the source reports, then attribute it against the canonical token ID
        _source.claim(_tokenId, currency0Amount, currency1Amount);
        onAmountsReceived(_tokenId, currency0Amount, currency1Amount);
    }

    /// @inheritdoc BaseClaimRecipient
    /// @notice Override to cap the amounts released for a given tokenId by the time since its last claim
    function _beforeClaimTransfer(uint256 _tokenId, Currency, Currency, uint256 _available0, uint256 _available1)
        internal
        override
        returns (address, uint256, address, uint256)
    {
        uint256 last = lastClaimed[_tokenId];
        uint256 blockNumber = _getBlockNumberish();
        if (last == 0) {
            lastClaimed[_tokenId] = blockNumber;
            emit VestingStarted(_tokenId, blockNumber);
            return (address(recipient), 0, address(recipient), 0);
        }

        uint256 blocksPassed = blockNumber - last;
        if (blocksPassed == 0) return (address(recipient), 0, address(recipient), 0);

        if ((_available0 > 0 && maxCurrency0PerBlock > 0) || (_available1 > 0 && maxCurrency1PerBlock > 0)) {
            lastClaimed[_tokenId] = blockNumber;
        }

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
