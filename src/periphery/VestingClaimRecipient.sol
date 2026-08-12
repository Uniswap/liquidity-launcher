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
/// @notice Contract which claims amounts from sources and releases them at a capped per-block rate
/// @dev Supports claiming from multiple sources but attributes all amounts to the canonical tokenId on PositionManager
/// @dev The vesting speed is chain specific and dependent on the block time.
/// @dev Positions are onboarded by transferring a beneficiary NFT in, or by attributing amounts directly through
///      `onAmountsReceived`. Neither is gated, so the per-tokenId release cap bounds one position's rate, not the
///      contract's aggregate rate across positions.
contract VestingClaimRecipient is BaseClaimRecipient, BlockNumberish, IERC721Receiver {
    /// @notice Thrown when the pinned recipient is zero or this contract
    /// @param recipient The invalid recipient
    error InvalidRecipient(IClaimableRecipient recipient);

    /// @notice The maximum currency0 amount releasable per block, per tokenId
    uint128 public immutable maxCurrency0PerBlock;

    /// @notice The maximum currency1 amount releasable per block, per tokenId
    uint128 public immutable maxCurrency1PerBlock;

    /// @notice The receiver of every release, fixed at deploy
    IClaimableRecipient public immutable recipient;

    /// @notice The block number of the last processed claim for a given tokenId, used to release at most once per block
    mapping(uint256 tokenId => uint256 lastClaimed) public lastClaimed;

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

    /// @inheritdoc BaseClaimRecipient
    /// @notice Override to cap the amounts released for a given tokenId at the per-block maximums
    /// @dev The cap does not accrue: at most one release of up to the maximums per block, regardless of
    ///      how long the position went unclaimed
    function _beforeClaimTransfer(uint256 _tokenId, Currency, Currency, uint256 _available0, uint256 _available1)
        internal
        override
        returns (address, uint256, address, uint256)
    {
        uint256 blockNumber = _getBlockNumberish();
        if (lastClaimed[_tokenId] == blockNumber) return (address(recipient), 0, address(recipient), 0);

        uint256 currency0Amount = FixedPointMathLib.min(_available0, maxCurrency0PerBlock);
        uint256 currency1Amount = FixedPointMathLib.min(_available1, maxCurrency1PerBlock);

        if (currency0Amount > 0 || currency1Amount > 0) {
            lastClaimed[_tokenId] = blockNumber;
        }

        return (address(recipient), currency0Amount, address(recipient), currency1Amount);
    }

    /// @inheritdoc BaseClaimRecipient
    /// @notice Calls `onAmountsReceived` on the recipient to register the transferred amounts
    function _afterClaim(PoolKey memory, uint256 _tokenId, uint256 _toSend0, uint256 _toSend1) internal override {
        recipient.onAmountsReceived(_tokenId, _toSend0, _toSend1);
    }
}
