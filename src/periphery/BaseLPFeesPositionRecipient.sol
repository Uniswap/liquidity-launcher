// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ILPFeesExecutor} from "../interfaces/ILPFeesExecutor.sol";
import {ILPFeesPositionRecipient} from "../interfaces/ILPFeesPositionRecipient.sol";
import {TimelockedPositionRecipient} from "./TimelockedPositionRecipient.sol";

/// @title BaseLPFeesPositionRecipient
/// @notice Shared fee collection and executor callback mechanics for LP position recipients
abstract contract BaseLPFeesPositionRecipient is ILPFeesPositionRecipient, TimelockedPositionRecipient {
    constructor(IPositionManager _positionManager, address _operator, uint256 _timelockBlockNumber)
        TimelockedPositionRecipient(_positionManager, _operator, _timelockBlockNumber)
    {}

    struct Fees {
        uint256 currency0Fees;
        uint256 currency1Fees;
    }
    mapping(uint256 tokenId => Fees fees) public override fees;
    mapping(Currency currency => uint256 amount) public totalFees;

    /// @notice Returns the pool key for an existing position
    function _getPoolKey(uint256 _tokenId) internal view returns (PoolKey memory poolKey) {
        (poolKey,) = positionManager.getPoolAndPositionInfo(_tokenId);
        if (poolKey.tickSpacing == 0) revert InvalidPosition(_tokenId);
    }

    /// @inheritdoc ILPFeesPositionRecipient
    /// @dev The position's currencies are fetched from the PositionManager: the caller is untrusted,
    ///      so notified amounts are attributed only to the pool the position actually belongs to.
    function onFeesReceived(uint256 _tokenId, uint256 _currency0Amount, uint256 _currency1Amount) external {
        PoolKey memory poolKey = _getPoolKey(_tokenId);

        Fees storage positionFees = fees[_tokenId];
        if (_currency0Amount != 0) {
            _attribute(poolKey.currency0, _currency0Amount);
            positionFees.currency0Fees += _currency0Amount;
        }
        if (_currency1Amount != 0) {
            _attribute(poolKey.currency1, _currency1Amount);
            positionFees.currency1Fees += _currency1Amount;
        }
    }

    /// @notice Verifies `_amount` of `_currency` is backed by this contract's balance beyond the
    ///         fees already attributed, then adds it to the attributed total.
    function _attribute(Currency _currency, uint256 _amount) private {
        uint256 balance = _currency.balanceOfSelf();
        uint256 expectedTotalFees = totalFees[_currency] + _amount;
        if (balance < expectedTotalFees) revert InsufficientAmountReceived(_currency, balance, expectedTotalFees);
        totalFees[_currency] = expectedTotalFees;
    }

    /// @inheritdoc ILPFeesPositionRecipient
    function collectFees(uint256 _tokenId, uint256 _minCurrency0Amount, uint256 _minCurrency1Amount)
        external
        nonReentrant
    {
        PoolKey memory poolKey = _getPoolKey(_tokenId);

        Currency currency0 = poolKey.currency0;
        Currency currency1 = poolKey.currency1;
        uint256 currency0Fees = fees[_tokenId].currency0Fees;
        uint256 currency1Fees = fees[_tokenId].currency1Fees;

        if (currency0Fees < _minCurrency0Amount) {
            revert InsufficientAmountReceived(currency0, currency0Fees, _minCurrency0Amount);
        }
        if (currency1Fees < _minCurrency1Amount) {
            revert InsufficientAmountReceived(currency1, currency1Fees, _minCurrency1Amount);
        }

        // Strict phase order: the policy is consulted once against the untouched pre-transfer state,
        // every returned value is validated, and only then does any payout execute.
        (address recipient0, uint256 toSend0, address recipient1, uint256 toSend1) =
            _beforeTransfer(_tokenId, currency0, currency1, currency0Fees, currency1Fees);
        if (recipient0 == address(0)) revert InvalidTransferRecipient(currency0);
        if (recipient1 == address(0)) revert InvalidTransferRecipient(currency1);
        if (toSend0 > currency0Fees) revert InsufficientAmountReceived(currency0, currency0Fees, toSend0);
        if (toSend1 > currency1Fees) revert InsufficientAmountReceived(currency1, currency1Fees, toSend1);

        _payout(_tokenId, currency0, recipient0, toSend0, true);
        _payout(_tokenId, currency1, recipient1, toSend1, false);

        uint256 context = _beforeCallback(poolKey, _tokenId);

        // EOAs and constructor callers have no code and skip this optional executor notification.
        // Implementations must secure collection through the outcome checks around it.
        if (msg.sender.code.length != 0) ILPFeesExecutor(msg.sender).callback(poolKey, _tokenId, toSend0, toSend1);

        _afterCallback(poolKey, _tokenId, context);

        emit FeesCollected(_tokenId, toSend0, toSend1, poolKey);
    }

    /// @notice Decrements one currency's attributed accounting and pays it out. Accounting strictly
    ///         precedes the transfer, so code running during a payout can neither re-collect
    ///         (reentrancy guard) nor attribute the in-flight funds (balance proof).
    function _payout(uint256 _tokenId, Currency _currency, address _recipient, uint256 _toSend, bool _isCurrency0)
        private
    {
        if (_toSend == 0) return;
        if (_isCurrency0) fees[_tokenId].currency0Fees -= _toSend;
        else fees[_tokenId].currency1Fees -= _toSend;
        totalFees[_currency] -= _toSend;
        _currency.transfer(_recipient, _toSend);
    }

    /// @notice Transfer policy consulted once per collect, against the pre-transfer state and before
    ///         any payout. The default pays the full available amounts to the caller. Overrides must
    ///         return exact values: the base rejects zero recipients so a careless override cannot
    ///         silently misroute funds — burning must be an explicit 0xdead. Returning an amount below
    ///         the available fees leaves the remainder attributed and claimable later.
    function _beforeTransfer(uint256, Currency, Currency, uint256 _available0, uint256 _available1)
        internal
        virtual
        returns (address recipient0, uint256 toSend0, address recipient1, uint256 toSend1)
    {
        return (msg.sender, _available0, msg.sender, _available1);
    }

    /// @notice Called before the callback is executed
    /// @return context An opaque value passed through to `_afterCallback`
    function _beforeCallback(PoolKey memory _poolKey, uint256 _tokenId) internal virtual returns (uint256 context) {}

    /// @notice Called after the callback is executed
    /// @param _context The value returned by `_beforeCallback`
    function _afterCallback(PoolKey memory _poolKey, uint256 _tokenId, uint256 _context) internal virtual {}
}
