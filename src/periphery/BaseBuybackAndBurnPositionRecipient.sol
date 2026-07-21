// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ILPFeesExecutor} from "../interfaces/ILPFeesExecutor.sol";
import {TimelockedPositionRecipient} from "./TimelockedPositionRecipient.sol";

/// @title BaseBuybackAndBurnPositionRecipient
/// @notice Shared fee collection and callback mechanics for LP position recipients
abstract contract BaseBuybackAndBurnPositionRecipient is TimelockedPositionRecipient {
    /// @notice Thrown when the position does not exist or has been burned
    error InvalidPosition(uint256 tokenId);

    /// @notice Thrown when the received amounts are less than expected
    error InsufficientAmountReceived(Currency currency, uint256 received, uint256 expected);

    /// @notice Emitted after fees are collected and processed by an executor
    event FeesCollected(uint256 indexed tokenId, uint256 currency0Received, uint256 currency1Received, PoolKey poolKey);

    /// @notice The address to send tokens to be burned
    address internal constant BURN_ADDRESS = address(0xdead);

    constructor(IPositionManager _positionManager, address _operator, uint256 _timelockBlockNumber)
        TimelockedPositionRecipient(_positionManager, _operator, _timelockBlockNumber)
    {}

    /// @notice Returns the pool key for an existing position
    function _getPoolKey(uint256 _tokenId) internal view returns (PoolKey memory poolKey) {
        (poolKey,) = positionManager.getPoolAndPositionInfo(_tokenId);
        if (poolKey.tickSpacing == 0) revert InvalidPosition(_tokenId);
    }

    /// @notice Collects a position's fees and lets the caller process them atomically
    /// @param _tokenId The token ID of the position
    /// @param _minCurrency0Amount The minimum acceptable currency0 fees
    /// @param _minCurrency1Amount The minimum acceptable currency1 fees
    function collectFees(uint256 _tokenId, uint256 _minCurrency0Amount, uint256 _minCurrency1Amount)
        external
        nonReentrant
    {
        PoolKey memory poolKey = _getPoolKey(_tokenId);

        Currency currency0 = poolKey.currency0;
        Currency currency1 = poolKey.currency1;

        uint256 currency0BalanceBefore = currency0.balanceOfSelf();
        uint256 currency1BalanceBefore = currency1.balanceOfSelf();

        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(_tokenId, 0, 0, 0, bytes(""));
        params[1] = abi.encode(currency0, currency1, address(this));

        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);

        uint256 currency0Received = currency0.balanceOfSelf() - currency0BalanceBefore;
        uint256 currency1Received = currency1.balanceOfSelf() - currency1BalanceBefore;

        if (currency0Received < _minCurrency0Amount) {
            revert InsufficientAmountReceived(currency0, currency0Received, _minCurrency0Amount);
        }
        if (currency1Received < _minCurrency1Amount) {
            revert InsufficientAmountReceived(currency1, currency1Received, _minCurrency1Amount);
        }

        if (currency0Received != 0) currency0.transfer(msg.sender, currency0Received);
        if (currency1Received != 0) currency1.transfer(msg.sender, currency1Received);

        _beforeCallback(poolKey, _tokenId, currency0Received, currency1Received);

        ILPFeesExecutor(msg.sender).callback(poolKey, _tokenId, currency0Received, currency1Received);

        _afterCallback(poolKey, _tokenId, currency0Received, currency1Received);

        emit FeesCollected(_tokenId, currency0Received, currency1Received, poolKey);
    }

    /// @notice Called before the callback is executed
    function _beforeCallback(
        PoolKey memory _poolKey,
        uint256 _tokenId,
        uint256 _currency0Received,
        uint256 _currency1Received
    ) internal virtual {}

    /// @notice Called after the callback is executed
    function _afterCallback(
        PoolKey memory _poolKey,
        uint256 _tokenId,
        uint256 _currency0Received,
        uint256 _currency1Received
    ) internal virtual {}
}
