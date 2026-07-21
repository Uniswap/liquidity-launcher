// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {TimelockedPositionRecipient} from "./TimelockedPositionRecipient.sol";

/// @title BaseBuybackAndBurnPositionRecipient
/// @notice Shared fee collection and burn mechanics for buyback-and-burn position recipients
abstract contract BaseBuybackAndBurnPositionRecipient is TimelockedPositionRecipient {
    /// @notice Thrown when the position does not exist or has been burned
    error InvalidPosition(uint256 tokenId);

    /// @notice Thrown when the received currency fees amount is less than expected
    error InsufficientCurrencyReceived(uint256 received, uint256 expected);

    /// @notice Thrown when the minimum token burn amount is zero
    error InvalidMinTokenBurnAmount();

    /// @notice The address to send tokens to be burned
    address internal constant BURN_ADDRESS = address(0xdead);

    /// @notice The minimum amount of token which must be burned each time fees are collected
    uint256 public immutable minTokenBurnAmount;

    constructor(
        IPositionManager _positionManager,
        address _operator,
        uint256 _timelockBlockNumber,
        uint256 _minTokenBurnAmount
    ) TimelockedPositionRecipient(_positionManager, _operator, _timelockBlockNumber) {
        if (_minTokenBurnAmount == 0) revert InvalidMinTokenBurnAmount();
        minTokenBurnAmount = _minTokenBurnAmount;
    }

    /// @notice Returns the pool key for an existing position
    function _getPoolKey(uint256 _tokenId) internal view returns (PoolKey memory poolKey) {
        (poolKey,) = positionManager.getPoolAndPositionInfo(_tokenId);
        if (poolKey.tickSpacing == 0) revert InvalidPosition(_tokenId);
    }

    /// @notice Pulls the configured minimum burn amount from the caller
    function _burnCallerTokens(Currency _token) internal {
        SafeTransferLib.safeTransferFrom(Currency.unwrap(_token), msg.sender, BURN_ADDRESS, minTokenBurnAmount);
    }

    /// @notice Collects a position's fees, burns its token fees, and pays its currency fees to the caller
    /// @return currencyReceived The currency fees received from this collection
    function _collectAndPayFees(uint256 _tokenId, uint256 _minCurrencyAmount, Currency _token, Currency _currency)
        internal
        returns (uint256 currencyReceived)
    {
        uint256 currencyBalanceBefore = _currency.balanceOfSelf();

        bytes memory actions =
            abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE), uint8(Actions.TAKE));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(_tokenId, 0, 0, 0, bytes(""));
        params[1] = abi.encode(_token, BURN_ADDRESS, ActionConstants.OPEN_DELTA);
        params[2] = abi.encode(_currency, address(this), ActionConstants.OPEN_DELTA);

        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);

        currencyReceived = _currency.balanceOfSelf() - currencyBalanceBefore;
        if (currencyReceived < _minCurrencyAmount) {
            revert InsufficientCurrencyReceived(currencyReceived, _minCurrencyAmount);
        }
        _currency.transfer(msg.sender, currencyReceived);
    }
}
