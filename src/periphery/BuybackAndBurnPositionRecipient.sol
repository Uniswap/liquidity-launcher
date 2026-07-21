// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BaseBuybackAndBurnPositionRecipient} from "./BaseBuybackAndBurnPositionRecipient.sol";

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
    /// @notice Thrown when the received currency fees amount is less than expected
    error InsufficientCurrencyReceived(uint256 received, uint256 expected);

    /// @notice Emitted when tokens are burned
    /// @param amount The amount of tokens burned
    event TokensBurned(uint256 amount);

    /// @notice Emitted when fees are collected
    /// @param caller The caller of the collectFees function
    event FeesCollected(address indexed caller);

    /// @notice The token that will be burned
    address public immutable token;
    /// @notice The currency that will be used to collect fees
    address public immutable currency;

    constructor(
        address _token,
        address _currency,
        address _operator,
        IPositionManager _positionManager,
        uint256 _timelockBlockNumber,
        uint256 _minTokenBurnAmount
    ) BaseBuybackAndBurnPositionRecipient(_positionManager, _operator, _timelockBlockNumber, _minTokenBurnAmount) {
        if (_token == address(0)) revert InvalidToken();
        if (_token == _currency) revert TokenAndCurrencyCannotBeTheSame();
        token = _token;
        currency = _currency;
    }

    /// @notice Claim any fees from the position and burn the `tokens` portion
    /// @param _tokenId The token ID of the position
    function collectFees(uint256 _tokenId, uint256 _minCurrencyAmount) external nonReentrant {
        PoolKey memory poolKey = _getPoolKey(_tokenId);
        Currency configuredToken = Currency.wrap(token);
        Currency configuredCurrency = Currency.wrap(currency);
        if (!((poolKey.currency0 == configuredToken && poolKey.currency1 == configuredCurrency)
                    || (poolKey.currency0 == configuredCurrency && poolKey.currency1 == configuredToken))) {
            revert InvalidPool(poolKey.currency0, poolKey.currency1);
        }

        // Require the caller to burn at least the minimum amount of `token`
        _burnCallerTokens(configuredToken);
        emit TokensBurned(minTokenBurnAmount);

        _collectAndPayFees(_tokenId, _minCurrencyAmount, configuredToken, configuredCurrency);

        emit FeesCollected(msg.sender);
    }
}
