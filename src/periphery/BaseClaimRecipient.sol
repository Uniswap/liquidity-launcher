// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {IClaimableRecipient} from "../interfaces/IClaimableRecipient.sol";

/// @title BaseClaimRecipient
/// @notice Shared amount attribution and claim mechanics for LP position recipients.
/// @dev `_afterClaim` is an empty hook; recipients that call back into an executor inherit
///      `BaseClaimRecipientWithCallback`.
abstract contract BaseClaimRecipient is IClaimableRecipient, ReentrancyGuardTransient {
    using SafeCast for uint256;

    /// @inheritdoc IClaimableRecipient
    IPositionManager public immutable override positionManager;

    /// @notice A position's attributed amounts, one per pool currency side.
    /// @param currency0Amount The attributed currency0 amount
    /// @param currency1Amount The attributed currency1 amount
    struct Amounts {
        uint128 currency0Amount;
        uint128 currency1Amount;
    }

    /// @inheritdoc IClaimableRecipient
    mapping(uint256 tokenId => Amounts amounts) public override amounts;

    /// @notice The total attributed amount per currency across all positions; every attribution must be
    ///         backed by at least this much balance.
    mapping(Currency currency => uint256 amount) public totalAmounts;

    constructor(IPositionManager _positionManager) {
        positionManager = _positionManager;
    }

    /// @inheritdoc IClaimableRecipient
    function onAmountsReceived(uint256 tokenId, uint256 currency0Amount, uint256 currency1Amount) external override {
        PoolKey memory poolKey = _getPoolKey(tokenId);

        Amounts memory positionAmounts = amounts[tokenId];
        if (currency0Amount != 0) {
            _attribute(poolKey.currency0, currency0Amount);
            positionAmounts.currency0Amount = (positionAmounts.currency0Amount + currency0Amount).toUint128();
        }
        if (currency1Amount != 0) {
            _attribute(poolKey.currency1, currency1Amount);
            positionAmounts.currency1Amount = (positionAmounts.currency1Amount + currency1Amount).toUint128();
        }
        amounts[tokenId] = positionAmounts;

        emit AmountsReceived(tokenId, currency0Amount, currency1Amount);
    }

    /// @inheritdoc IClaimableRecipient
    function claim(uint256 tokenId, uint256 minCurrency0Amount, uint256 minCurrency1Amount)
        external
        override
        nonReentrant
    {
        PoolKey memory poolKey = _getPoolKey(tokenId);

        Currency currency0 = poolKey.currency0;
        Currency currency1 = poolKey.currency1;
        Amounts memory positionAmounts = amounts[tokenId];
        uint256 currency0Amount = positionAmounts.currency0Amount;
        uint256 currency1Amount = positionAmounts.currency1Amount;

        if (currency0Amount < minCurrency0Amount) {
            revert InsufficientAmountReceived(currency0, currency0Amount, minCurrency0Amount);
        }
        if (currency1Amount < minCurrency1Amount) {
            revert InsufficientAmountReceived(currency1, currency1Amount, minCurrency1Amount);
        }

        (address recipient0, uint256 toSend0, address recipient1, uint256 toSend1) =
            _beforeClaimTransfer(tokenId, currency0, currency1, currency0Amount, currency1Amount);
        if (recipient0 == address(0)) revert InvalidTransferRecipient(currency0);
        if (recipient1 == address(0)) revert InvalidTransferRecipient(currency1);
        if (toSend0 > currency0Amount) revert InsufficientAmountReceived(currency0, currency0Amount, toSend0);
        if (toSend1 > currency1Amount) revert InsufficientAmountReceived(currency1, currency1Amount, toSend1);

        _payout(tokenId, currency0, recipient0, toSend0, true);
        _payout(tokenId, currency1, recipient1, toSend1, false);

        _afterClaim(poolKey, tokenId, toSend0, toSend1);

        emit Claimed(tokenId, toSend0, toSend1, poolKey);
    }

    /// @notice Returns the pool key for an existing position
    function _getPoolKey(uint256 tokenId) internal view returns (PoolKey memory poolKey) {
        (poolKey,) = positionManager.getPoolAndPositionInfo(tokenId);
        if (poolKey.tickSpacing == 0) revert InvalidPosition(tokenId);
    }

    /// @notice Transfer policy consulted once per claim, before any payout; defaults to paying the
    ///         full available amounts to the caller.
    /// @dev Zero recipients revert; burns must target 0xdead. Amounts below the available balance
    ///      leave the remainder claimable later.
    /// @return The receiver of the currency0 payout
    /// @return The currency0 amount to pay out; at most the available amount
    /// @return The receiver of the currency1 payout
    /// @return The currency1 amount to pay out; at most the available amount
    function _beforeClaimTransfer(uint256, Currency, Currency, uint256 available0, uint256 available1)
        internal
        virtual
        returns (address, uint256, address, uint256)
    {
        return (msg.sender, available0, msg.sender, available1);
    }

    /// @notice Hook run after both payouts; empty by default. Overrides must not modify the
    ///         attribution accounting.
    /// @param poolKey The claimed position's pool key
    /// @param tokenId The claimed position's token ID
    /// @param toSend0 The currency0 amount paid out in this claim
    /// @param toSend1 The currency1 amount paid out in this claim
    function _afterClaim(PoolKey memory poolKey, uint256 tokenId, uint256 toSend0, uint256 toSend1) internal virtual {}

    /// @notice Decrements attribution before transferring.
    /// @param tokenId The position being claimed
    /// @param currency The currency to pay out
    /// @param recipient The receiver of the payout
    /// @param toSend The amount to pay out
    /// @param isCurrency0 Whether `currency` is the position's currency0
    function _payout(uint256 tokenId, Currency currency, address recipient, uint256 toSend, bool isCurrency0) private {
        if (toSend == 0) return;
        // casts are safe as toSend is bounded by the attributed uint128 amount
        if (isCurrency0) {
            amounts[tokenId].currency0Amount -= uint128(toSend);
        } else {
            amounts[tokenId].currency1Amount -= uint128(toSend);
        }
        totalAmounts[currency] -= toSend;
        currency.transfer(recipient, toSend);
    }

    /// @notice Requires `amount` to be backed by balance beyond the amounts already attributed.
    /// @param currency The currency being attributed
    /// @param amount The amount to attribute
    function _attribute(Currency currency, uint256 amount) private {
        uint256 balance = currency.balanceOfSelf();
        uint256 expectedTotalAmount = totalAmounts[currency] + amount;
        if (balance < expectedTotalAmount) revert InsufficientAmountReceived(currency, balance, expectedTotalAmount);
        totalAmounts[currency] = expectedTotalAmount;
    }

    /// @notice Receive ETH
    receive() external payable {}
}
