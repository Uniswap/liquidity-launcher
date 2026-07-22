// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
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

    error InvalidCurrency(Currency currency);

    struct Fees {
        uint256 currency0Fees;
        uint256 currency1Fees;
    }
    mapping(uint256 tokenId => Fees fees) public override fees;

    /// @notice Returns the pool key for an existing position
    function _getPoolKey(uint256 _tokenId) internal view returns (PoolKey memory poolKey) {
        (poolKey,) = positionManager.getPoolAndPositionInfo(_tokenId);
        if (poolKey.tickSpacing == 0) revert InvalidPosition(_tokenId);
    }

    /// @inheritdoc ILPFeesPositionRecipient
    function onFeesReceived(uint256 _tokenId, Currency _currency, uint256 _amount) external {
        PoolKey memory poolKey = _getPoolKey(_tokenId);
        Currency currency0 = poolKey.currency0;
        Currency currency1 = poolKey.currency1;
        if (_currency != currency0 && _currency != currency1) revert InvalidCurrency(_currency);
        Fees storage fees = fees[_tokenId];

        if (_currency == currency0) {
            uint256 expectedCurrency0Fees = fees.currency0Fees + _amount;
            if (currency0.balanceOfSelf() < expectedCurrency0Fees) {
                revert InsufficientAmountReceived(currency0, currency0.balanceOfSelf(), expectedCurrency0Fees);
            }
            fees.currency0Fees += _amount;
        } else {
            uint256 expectedCurrency1Fees = fees.currency1Fees + _amount;
            if (currency1.balanceOfSelf() < expectedCurrency1Fees) {
                revert InsufficientAmountReceived(currency1, currency1.balanceOfSelf(), expectedCurrency1Fees);
            }
            fees.currency1Fees += _amount;
        }
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
        if (currency0Fees != 0) currency0.transfer(msg.sender, currency0Fees);
        if (currency1Fees != 0) currency1.transfer(msg.sender, currency1Fees);

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
