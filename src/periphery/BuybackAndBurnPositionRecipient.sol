// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BaseBuybackAndBurnPositionRecipient} from "./BaseBuybackAndBurnPositionRecipient.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title BuybackAndBurnPositionRecipient
/// @notice Utility contract for holding a v4 LP position and burning the fees accrued from the position
/// @dev Fees can be collected once the value of the currency portion exceeds the configured minimum burn amount
contract BuybackAndBurnPositionRecipient is BaseBuybackAndBurnPositionRecipient {
    /// @notice Thrown when the token is address(0)
    error InvalidToken();
    /// @notice Thrown when the token and currency are the same address
    error TokenAndCurrencyCannotBeTheSame();
    /// @notice Thrown when the position does not use the configured token and currency
    error InvalidPool(Currency currency0, Currency currency1);
    /// @notice Thrown when the minimum token burn amount is zero
    error InvalidMinTokenBurnAmount();

    /// @notice Emitted when tokens are burned
    /// @param amount The amount of tokens burned
    event TokensBurned(uint256 amount);

    /// @notice The token that will be burned
    address public immutable token;
    /// @notice The currency that will be used to collect fees
    address public immutable currency;
    /// @notice The minimum amount of token that the executor must burn
    uint256 public immutable minTokenBurnAmount;

    constructor(
        address _token,
        address _currency,
        address _operator,
        IPositionManager _positionManager,
        uint256 _timelockBlockNumber,
        uint256 _minTokenBurnAmount
    ) BaseBuybackAndBurnPositionRecipient(_positionManager, _operator, _timelockBlockNumber) {
        if (_token == address(0)) revert InvalidToken();
        if (_token == _currency) revert TokenAndCurrencyCannotBeTheSame();
        if (_minTokenBurnAmount == 0) revert InvalidMinTokenBurnAmount();
        token = _token;
        currency = _currency;
        minTokenBurnAmount = _minTokenBurnAmount;
    }

    /// @inheritdoc BaseBuybackAndBurnPositionRecipient
    /// @dev Requires that the position uses the configured pair
    function _beforeCallback(PoolKey memory _poolKey, uint256, uint256, uint256) internal view override {
        Currency configuredToken = Currency.wrap(token);
        Currency configuredCurrency = Currency.wrap(currency);
        if (!((_poolKey.currency0 == configuredToken && _poolKey.currency1 == configuredCurrency)
                    || (_poolKey.currency0 == configuredCurrency && _poolKey.currency1 == configuredToken))) {
            revert InvalidPool(_poolKey.currency0, _poolKey.currency1);
        }
    }

    /// @inheritdoc BaseBuybackAndBurnPositionRecipient
    /// @dev Always burns the specified token
    function _afterCallback(PoolKey memory, uint256, uint256, uint256) internal override {
        SafeTransferLib.safeTransferFrom(token, msg.sender, BURN_ADDRESS, minTokenBurnAmount);
        emit TokensBurned(minTokenBurnAmount);
    }
}
