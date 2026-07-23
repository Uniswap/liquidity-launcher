// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IClaimExecutor} from "../interfaces/IClaimExecutor.sol";
import {IClaimablePositionRecipient} from "../interfaces/IClaimablePositionRecipient.sol";
import {TimelockedPositionRecipient} from "./TimelockedPositionRecipient.sol";

/// @title BasePositionRecipient
/// @notice Shared amount attribution and executor claim mechanics for LP position recipients
abstract contract BasePositionRecipient is IClaimablePositionRecipient, TimelockedPositionRecipient {
    constructor(IPositionManager _positionManager, address _operator, uint256 _timelockBlockNumber)
        TimelockedPositionRecipient(_positionManager, _operator, _timelockBlockNumber)
    {}

    struct Amounts {
        uint256 currency0Amount;
        uint256 currency1Amount;
    }
    mapping(uint256 tokenId => Amounts amounts) public override amounts;
    mapping(Currency currency => uint256 amount) public totalAmounts;

    /// @notice Returns the pool key for an existing position
    function _getPoolKey(uint256 _tokenId) internal view returns (PoolKey memory poolKey) {
        (poolKey,) = positionManager.getPoolAndPositionInfo(_tokenId);
        if (poolKey.tickSpacing == 0) revert InvalidPosition(_tokenId);
    }

    /// @inheritdoc IClaimablePositionRecipient
    /// @dev The position's currencies are fetched from the PositionManager: the caller is untrusted,
    ///      so notified amounts are attributed only to the pool the position actually belongs to.
    function onAmountsReceived(uint256 _tokenId, uint256 _currency0Amount, uint256 _currency1Amount) external {
        PoolKey memory poolKey = _getPoolKey(_tokenId);

        Amounts storage positionAmounts = amounts[_tokenId];
        if (_currency0Amount != 0) {
            _attribute(poolKey.currency0, _currency0Amount);
            positionAmounts.currency0Amount += _currency0Amount;
        }
        if (_currency1Amount != 0) {
            _attribute(poolKey.currency1, _currency1Amount);
            positionAmounts.currency1Amount += _currency1Amount;
        }
    }

    /// @notice Verifies `_amount` of `_currency` is backed by this contract's balance beyond the
    ///         amounts already attributed, then adds it to the attributed total.
    function _attribute(Currency _currency, uint256 _amount) private {
        uint256 balance = _currency.balanceOfSelf();
        uint256 expectedTotalAmount = totalAmounts[_currency] + _amount;
        if (balance < expectedTotalAmount) revert InsufficientAmountReceived(_currency, balance, expectedTotalAmount);
        totalAmounts[_currency] = expectedTotalAmount;
    }

    /// @inheritdoc IClaimablePositionRecipient
    function claim(uint256 _tokenId, uint256 _minCurrency0Amount, uint256 _minCurrency1Amount) external nonReentrant {
        PoolKey memory poolKey = _getPoolKey(_tokenId);

        Currency currency0 = poolKey.currency0;
        Currency currency1 = poolKey.currency1;
        uint256 currency0Amount = amounts[_tokenId].currency0Amount;
        uint256 currency1Amount = amounts[_tokenId].currency1Amount;

        if (currency0Amount < _minCurrency0Amount) {
            revert InsufficientAmountReceived(currency0, currency0Amount, _minCurrency0Amount);
        }
        if (currency1Amount < _minCurrency1Amount) {
            revert InsufficientAmountReceived(currency1, currency1Amount, _minCurrency1Amount);
        }

        delete amounts[_tokenId];
        totalAmounts[currency0] -= currency0Amount;
        totalAmounts[currency1] -= currency1Amount;

        if (currency0Amount != 0) currency0.transfer(msg.sender, currency0Amount);
        if (currency1Amount != 0) currency1.transfer(msg.sender, currency1Amount);

        uint256 context = _beforeCallback(poolKey, _tokenId);

        IClaimExecutor(msg.sender).callback(poolKey, _tokenId, currency0Amount, currency1Amount);

        _afterCallback(poolKey, _tokenId, context);

        emit Claimed(_tokenId, currency0Amount, currency1Amount, poolKey);
    }

    /// @notice Called before the callback is executed
    /// @return context An opaque value passed through to `_afterCallback`
    function _beforeCallback(PoolKey memory _poolKey, uint256 _tokenId) internal virtual returns (uint256 context) {}

    /// @notice Called after the callback is executed
    /// @param _context The value returned by `_beforeCallback`
    function _afterCallback(PoolKey memory _poolKey, uint256 _tokenId, uint256 _context) internal virtual {}
}
