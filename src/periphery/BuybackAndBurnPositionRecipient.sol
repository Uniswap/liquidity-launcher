// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BaseLPFeesPositionRecipient} from "./BaseLPFeesPositionRecipient.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title BuybackAndBurnPositionRecipient
/// @notice Utility contract for holding a v4 LP position and burning the fees accrued from the position
/// @dev An executor collects the fees, buys back the configured token in its callback, and must let the
///      recipient pull at least the minimum burn amount of the token before the call completes
contract BuybackAndBurnPositionRecipient is BaseLPFeesPositionRecipient {
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

    /// @notice The address to send tokens to be burned
    address internal constant BURN_ADDRESS = address(0xdead);

    /// @notice The token that will be burned
    address public immutable token;
    /// @notice The currency that will be used to collect fees
    address public immutable currency;
    /// @notice The minimum amount of token that the executor must burn
    uint256 public immutable minTokenBurnAmount;

    /// @dev The configured pair sorted as pool currencies (currency0 < currency1)
    Currency private immutable expectedCurrency0;
    Currency private immutable expectedCurrency1;

    constructor(
        address _token,
        address _currency,
        address _operator,
        IPositionManager _positionManager,
        uint256 _timelockBlockNumber,
        uint256 _minTokenBurnAmount
    ) BaseLPFeesPositionRecipient(_positionManager, _operator, _timelockBlockNumber) {
        if (_token == address(0)) revert InvalidToken();
        if (_token == _currency) revert TokenAndCurrencyCannotBeTheSame();
        if (_minTokenBurnAmount == 0) revert InvalidMinTokenBurnAmount();
        token = _token;
        currency = _currency;
        minTokenBurnAmount = _minTokenBurnAmount;
        (expectedCurrency0, expectedCurrency1) = _token < _currency
            ? (Currency.wrap(_token), Currency.wrap(_currency))
            : (Currency.wrap(_currency), Currency.wrap(_token));
    }

    /// @inheritdoc BaseLPFeesPositionRecipient
    /// @dev Requires that the position uses the configured pair
    function _beforeCallback(PoolKey memory _poolKey, uint256) internal view override returns (uint256) {
        if (!(_poolKey.currency0 == expectedCurrency0 && _poolKey.currency1 == expectedCurrency1)) {
            revert InvalidPool(_poolKey.currency0, _poolKey.currency1);
        }
        return 0;
    }

    /// @inheritdoc BaseLPFeesPositionRecipient
    /// @dev Always burns the specified token
    function _afterCallback(PoolKey memory, uint256, uint256) internal override {
        SafeTransferLib.safeTransferFrom(token, msg.sender, BURN_ADDRESS, minTokenBurnAmount);
        emit TokensBurned(minTokenBurnAmount);
    }
}
