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

        delete fees[_tokenId];
        if (currency0Fees != 0) {
            currency0.transfer(msg.sender, currency0Fees);
            totalFees[currency0] -= currency0Fees;
        }
        if (currency1Fees != 0) {
            currency1.transfer(msg.sender, currency1Fees);
            totalFees[currency1] -= currency1Fees;
        }

        uint256 context = _beforeCallback(poolKey, _tokenId);

        ILPFeesExecutor(msg.sender).callback(poolKey, _tokenId, currency0Fees, currency1Fees);

        _afterCallback(poolKey, _tokenId, context);

        emit FeesCollected(_tokenId, currency0Fees, currency1Fees, poolKey);
    }

    /// @notice Called before the callback is executed
    /// @return context An opaque value passed through to `_afterCallback`
    function _beforeCallback(PoolKey memory _poolKey, uint256 _tokenId) internal virtual returns (uint256 context) {}

    /// @notice Called after the callback is executed
    /// @param _context The value returned by `_beforeCallback`
    function _afterCallback(PoolKey memory _poolKey, uint256 _tokenId, uint256 _context) internal virtual {}
}
