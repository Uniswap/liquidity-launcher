// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {TimelockedPositionRecipient} from "./TimelockedPositionRecipient.sol";

/// @title BuybackAndBurnPositionRecipient
/// @notice Utility contract for holding a v4 LP position and burning the fees accrued from the position
/// @dev Fees can be collected once the value of the currency portion exceeds the configured minimum burn amount
contract BuybackAndBurnPositionRecipient is TimelockedPositionRecipient {
    using CurrencyLibrary for Currency;

    /// @notice Thrown when the token is address(0)
    error InvalidToken();
    /// @notice Thrown when the token and currency are the same address
    error TokenAndCurrencyCannotBeTheSame();
    /// @notice Thrown when the received currency fees amount is less than expected
    error InsufficientCurrencyReceived(uint256 received, uint256 expected);

    /// @notice Emitted when tokens are burned
    /// @param amount The amount of tokens burned
    event TokensBurned(uint256 amount);

    /// @notice Emitted when fees are collected
    /// @param caller The caller of the collectFees function
    event FeesCollected(address indexed caller);

    /// @notice The minimum amount of `token` which must be burned each time fees are collected
    uint256 public immutable minTokenBurnAmount;
    /// @notice The token that will be burned
    address public immutable token;
    /// @notice The currency that will be used to collect fees
    address public immutable currency;
    /// @notice The address to send tokens to be burned
    address constant BURN_ADDRESS = address(0xdead);

    constructor(
        address _token,
        address _currency,
        address _operator,
        IPositionManager _positionManager,
        uint256 _timelockBlockNumber,
        uint256 _minTokenBurnAmount
    ) TimelockedPositionRecipient(_positionManager, _operator, _timelockBlockNumber) {
        if (_token == address(0)) revert InvalidToken();
        if (_token == _currency) revert TokenAndCurrencyCannotBeTheSame();
        token = _token;
        currency = _currency;
        minTokenBurnAmount = _minTokenBurnAmount;
    }

    /// @notice Claim any fees from the position and burn the `tokens` portion
    /// @param _tokenId The token ID of the position
    function collectFees(uint256 _tokenId, uint256 _minCurrencyAmount) external nonReentrant {
        // Require the caller to burn at least the minimum amount of `token`
        SafeTransferLib.safeTransferFrom(token, msg.sender, BURN_ADDRESS, minTokenBurnAmount);
        emit TokensBurned(minTokenBurnAmount);

        // Collect the fees from the position
        bytes memory actions =
            abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE), uint8(Actions.TAKE));
        bytes[] memory params = new bytes[](3);
        // Call DECREASE_LIQUIDITY with a liquidity of 0 to collect fees
        params[0] = abi.encode(_tokenId, 0, 0, 0, bytes(""));
        // Call TAKE to send the tokens to the burn address
        params[1] = abi.encode(token, BURN_ADDRESS, ActionConstants.OPEN_DELTA);
        // Call TAKE to send the currency to this contract
        params[2] = abi.encode(currency, address(this), ActionConstants.OPEN_DELTA);

        // Set deadline to the current block
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);

        // Check received currency amount and transfer to caller
        uint256 currencyReceived = Currency.wrap(currency).balanceOfSelf();
        if (currencyReceived < _minCurrencyAmount) {
            revert InsufficientCurrencyReceived(currencyReceived, _minCurrencyAmount);
        }
        // Transfer the currency balance to the caller via CurrencyLibrary
        Currency.wrap(currency).transfer(msg.sender, currencyReceived);

        emit FeesCollected(msg.sender);
    }
}
