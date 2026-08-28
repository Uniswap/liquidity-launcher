// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IFeeSplitter, FeeSplit} from "../interfaces/IFeeSplitter.sol";
import {IClaimableRecipient} from "../interfaces/IClaimableRecipient.sol";

/// @title FeeSplitter
/// @notice Immutable-configuration custodian of v4 LP positions pairing a configured quote currency
///         that permissionlessly collects their fees and pushes independent fixed splits for the
///         quote and token sides.
/// @dev Every serviced position's pool must contain the quote currency on either side; the other
///      side is the token side.
/// @dev Positions sent to this contract are permanently locked and cannot be removed.
/// @dev Positions requiring hookData are not supported and should not be sent to this contract.
/// @custom:security-contact security@uniswap.org
contract FeeSplitter is IFeeSplitter, IERC721Receiver, ReentrancyGuardTransient {
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    /// @notice The denominator for fee splits
    uint256 public constant BPS_DENOMINATOR = 10_000;
    /// @notice The maximum possible balance to prevent overflows
    uint256 public constant MAX_BALANCE_ALLOWED = type(uint256).max / BPS_DENOMINATOR;

    /// @inheritdoc IFeeSplitter
    IPositionManager public immutable override positionManager;

    /// @notice The PoolManager the PositionManager is bound to.
    IPoolManager public immutable poolManager;

    /// @inheritdoc IFeeSplitter
    Currency public immutable override quoteCurrency;

    /// @notice The fee splits. Immutable after construction.
    FeeSplit[] internal _splits;

    /// @param _positionManager The canonical v4 PositionManager.
    /// @param _quoteCurrency The quote currency every serviced position must pair on one side.
    constructor(IPositionManager _positionManager, Currency _quoteCurrency, FeeSplit[] memory splits_) {
        positionManager = _positionManager;
        poolManager = _positionManager.poolManager();
        quoteCurrency = _quoteCurrency;
        _validateAndStoreSplits(splits_);
    }

    /// @inheritdoc IFeeSplitter
    function getSplits() external view override returns (FeeSplit[] memory) {
        return _splits;
    }

    /// @inheritdoc IFeeSplitter
    function collectFees(uint256[] calldata tokenIds) external override nonReentrant {
        uint256 count = tokenIds.length;
        if (count == 0) revert NoTokenIds();
        // collect opens its own lock so revert if the pool manager is already unlocked
        if (poolManager.isUnlocked()) revert PoolManagerAlreadyUnlocked();
        for (uint256 i; i < count; i++) {
            uint256 tokenId = tokenIds[i];
            if (IERC721(address(positionManager)).ownerOf(tokenId) != address(this)) {
                revert NotOwner(tokenId);
            }
            (Currency tokenCurrency, uint256 quoteAmount, uint256 tokenAmount, bool currency0IsQuote) =
                _collect(tokenId);
            if (quoteAmount != 0 || tokenAmount != 0) {
                _distribute(tokenId, tokenCurrency, quoteAmount, tokenAmount, currency0IsQuote);
            }
        }
    }

    /// @inheritdoc IFeeSplitter
    /// @dev Reverts if fees are not collected first
    function increaseLiquidity(
        uint256 tokenId,
        uint256 liquidity,
        uint128 amount0Max,
        uint128 amount1Max,
        bytes calldata hookData
    ) external override nonReentrant {
        if (IERC721(address(positionManager)).ownerOf(tokenId) != address(this)) {
            revert NotOwner(tokenId);
        }
        (PoolKey memory poolKey, PositionInfo info) = positionManager.getPoolAndPositionInfo(tokenId);
        _requireQuoteInPool(tokenId, poolKey);
        _requireNoPendingFees(tokenId, poolKey, info);

        // A native currency0 (the only side that can be native) is settled from unwrapped WETH, so
        // callers fund native pools in WETH; ERC20 pools settle their PositionManager balances directly.
        bool unwrapNative = poolKey.currency0.isAddressZero();
        bytes memory actions;
        bytes[] memory params;
        uint256 offset;
        if (unwrapNative) {
            actions = abi.encodePacked(
                uint8(Actions.UNWRAP),
                uint8(Actions.SETTLE),
                uint8(Actions.SETTLE),
                uint8(Actions.INCREASE_LIQUIDITY),
                uint8(Actions.TAKE_PAIR)
            );
            params = new bytes[](5);
            params[0] = abi.encode(ActionConstants.CONTRACT_BALANCE);
            offset = 1;
        } else {
            actions = abi.encodePacked(
                uint8(Actions.SETTLE),
                uint8(Actions.SETTLE),
                uint8(Actions.INCREASE_LIQUIDITY),
                uint8(Actions.TAKE_PAIR)
            );
            params = new bytes[](4);
        }
        // Require the balance to already exist in PositionManager
        params[offset] = abi.encode(poolKey.currency0, ActionConstants.CONTRACT_BALANCE, false);
        params[offset + 1] = abi.encode(poolKey.currency1, ActionConstants.CONTRACT_BALANCE, false);
        params[offset + 2] = abi.encode(tokenId, liquidity, amount0Max, amount1Max, hookData);
        params[offset + 3] = abi.encode(poolKey.currency0, poolKey.currency1, msg.sender);
        // modifyLiquidities opens its own lock, which reverts when the caller already holds one.
        if (poolManager.isUnlocked()) {
            positionManager.modifyLiquiditiesWithoutUnlock(actions, params);
        } else {
            positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);
        }
    }

    /// @notice Accepts positions safe-transferred through the PositionManager; the operator, sender,
    ///         token ID, and transfer data are all ignored.
    /// @dev Reverts with `NotPositionManager` if any other contract calls this.
    /// @return The `onERC721Received` selector.
    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != address(positionManager)) revert NotPositionManager(msg.sender);
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice Receives native ETH from the PositionManager take.
    receive() external payable {}

    /// @notice Reverts with UncollectedFees if the position has accrued fees since its last modification.
    /// @param tokenId The position token ID.
    /// @param poolKey The position's pool key.
    /// @param info The position's packed info, carrying its tick range.
    function _requireNoPendingFees(uint256 tokenId, PoolKey memory poolKey, PositionInfo info) private view {
        PoolId poolId = poolKey.toId();
        (uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128) = poolManager.getPositionInfo(
            poolId, address(positionManager), info.tickLower(), info.tickUpper(), bytes32(tokenId)
        );
        // A zero-liquidity position accrues nothing; its last modification realized everything.
        if (liquidity == 0) return;
        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) =
            poolManager.getFeeGrowthInside(poolId, info.tickLower(), info.tickUpper());
        if (feeGrowthInside0X128 != feeGrowthInside0LastX128 || feeGrowthInside1X128 != feeGrowthInside1LastX128) {
            revert UncollectedFees(tokenId);
        }
    }

    /// @notice Reverts with QuoteCurrencyNotInPool unless one of the pool's currencies is the quote.
    /// @param tokenId The position token ID.
    /// @param poolKey The position's pool key.
    /// @return currency0IsQuote Whether the pool's currency0 is the quote currency.
    function _requireQuoteInPool(uint256 tokenId, PoolKey memory poolKey) private view returns (bool currency0IsQuote) {
        currency0IsQuote = poolKey.currency0 == quoteCurrency;
        if (!currency0IsQuote && !(poolKey.currency1 == quoteCurrency)) revert QuoteCurrencyNotInPool(tokenId);
    }

    /// @notice Realizes one position's accrued fees into this contract's balances.
    /// @param tokenId The position token ID.
    /// @return tokenCurrency The position's token-side currency (the side that is not the quote).
    /// @return quoteAmount The full standing quote currency balance to distribute.
    /// @return tokenAmount The full standing token-side balance to distribute.
    /// @return currency0IsQuote Whether the pool's currency0 is the quote currency.
    function _collect(uint256 tokenId)
        private
        returns (Currency tokenCurrency, uint256 quoteAmount, uint256 tokenAmount, bool currency0IsQuote)
    {
        (PoolKey memory poolKey,) = positionManager.getPoolAndPositionInfo(tokenId);
        currency0IsQuote = _requireQuoteInPool(tokenId, poolKey);
        tokenCurrency = currency0IsQuote ? poolKey.currency1 : poolKey.currency0;

        // A zero-liquidity decrease realizes only the position's accrued fees.
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, 0, 0, 0, bytes(""));
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1, address(this));
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);

        // Distribute the full standing balances; donations are flushed through the split.
        quoteAmount = quoteCurrency.balanceOfSelf();
        tokenAmount = tokenCurrency.balanceOfSelf();
        if (quoteAmount > MAX_BALANCE_ALLOWED || tokenAmount > MAX_BALANCE_ALLOWED) {
            revert BalanceExceedsMaxAllowed(tokenId);
        }
        emit FeesCollected(tokenId, Currency.unwrap(tokenCurrency), quoteAmount, tokenAmount);
    }

    /// @notice Distributes amounts to each recipient based on the configured splits
    /// @param tokenId The collected position tokenId
    /// @param tokenCurrency The position's token-side currency.
    /// @param quoteAmount The quote currency amount to distribute.
    /// @param tokenAmount The token-side amount to distribute.
    /// @param currency0IsQuote Whether the pool's currency0 is the quote currency.
    function _distribute(
        uint256 tokenId,
        Currency tokenCurrency,
        uint256 quoteAmount,
        uint256 tokenAmount,
        bool currency0IsQuote
    ) private {
        uint256 count = _splits.length;
        for (uint256 i; i < count; i++) {
            FeeSplit memory split = _splits[i];
            uint256 recipientQuoteAmount = quoteAmount * split.quoteBps / BPS_DENOMINATOR;
            uint256 recipientTokenAmount = tokenAmount * split.tokenBps / BPS_DENOMINATOR;
            if (recipientQuoteAmount == 0 && recipientTokenAmount == 0) continue;
            address recipient = split.recipient;
            if (recipientQuoteAmount != 0) _transfer(quoteCurrency, recipient, recipientQuoteAmount);
            if (recipientTokenAmount != 0) _transfer(tokenCurrency, recipient, recipientTokenAmount);
            if (split.useCallback) {
                // Recipients implementing callbacks must NOT revert as it will cause the entire collect to revert
                // Callers should exclude tokenIds which consistently revert from callbacks.
                // Amounts are notified in pool-key order so recipients attribute them positionally.
                IClaimableRecipient(recipient)
                    .onAmountsReceived(
                        tokenId,
                        currency0IsQuote ? recipientQuoteAmount : recipientTokenAmount,
                        currency0IsQuote ? recipientTokenAmount : recipientQuoteAmount
                    );
            }
        }
    }

    /// @notice Native transfers are force-sent so a recipient cannot block a collect by rejecting ETH.
    function _transfer(Currency currency, address recipient, uint256 amount) private {
        if (currency.isAddressZero()) {
            SafeTransferLib.forceSafeTransferETH(recipient, amount);
        } else {
            SafeTransferLib.safeTransfer(Currency.unwrap(currency), recipient, amount);
        }
        emit FeesForwarded(recipient, currency, amount);
    }

    /// @notice Each side's shares must independently sum to the bps denominator; a split may carry a
    ///         single side but not neither.
    function _validateAndStoreSplits(FeeSplit[] memory splits_) private {
        uint256 count = splits_.length;
        if (count == 0) revert NoSplits();
        uint256 totalQuoteBps;
        uint256 totalTokenBps;
        for (uint256 i; i < count; i++) {
            FeeSplit memory split = splits_[i];
            if (split.recipient == address(0) || split.recipient == address(this)) {
                revert InvalidRecipient(split.recipient);
            }
            if (split.quoteBps == 0 && split.tokenBps == 0) revert ZeroSplitBps(split.recipient);
            if (split.useCallback && split.recipient.code.length == 0) {
                revert CallbackRecipientNotContract(split.recipient);
            }
            for (uint256 j; j < i; j++) {
                if (splits_[j].recipient == split.recipient) revert DuplicateRecipient(split.recipient);
            }
            totalQuoteBps += split.quoteBps;
            totalTokenBps += split.tokenBps;
            _splits.push(split);
        }
        if (totalQuoteBps != BPS_DENOMINATOR) revert InvalidSplitTotal(totalQuoteBps);
        if (totalTokenBps != BPS_DENOMINATOR) revert InvalidSplitTotal(totalTokenBps);
    }
}
