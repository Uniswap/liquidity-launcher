// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {TimelockedPositionRecipient} from "./TimelockedPositionRecipient.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @title BuybackAndBurnPositionRecipient
/// @notice Utility contract for holding a v4 LP position and burning the fees accrued from the position
/// @dev Fees can be collected once the value of the currency portion exceeds the configured minimum burn amount
contract BuybackAndBurnPositionRecipient is TimelockedPositionRecipient {
    using CurrencyLibrary for Currency;

    /// @notice Thrown when the token is address(0)
    error InvalidToken();
    /// @notice Thrown when the token and currency are the same address
    error TokenAndCurrencyCannotBeTheSame();

    /// @notice Emitted when tokens are burned
    /// @param amount The amount of tokens burned
    event TokensBurned(uint256 amount);

    /// @notice Emitted when fees are collected
    /// @param recipient The recipient of the currency fees
    /// @param amount The amount of currency fees collected
    event CurrencyFeesCollected(address indexed recipient, uint256 amount);

    /// @notice The minimum amount of `token` which must be burned each time fees are collected
    uint256 public immutable minTokenBurnAmount;
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
    ) TimelockedPositionRecipient(_positionManager, _operator, _timelockBlockNumber) {
        if (_token == address(0)) revert InvalidToken();
        if (_token == _currency) revert TokenAndCurrencyCannotBeTheSame();
        token = _token;
        currency = _currency;
        minTokenBurnAmount = _minTokenBurnAmount;
    }

    /// @notice Claim any fees from the position and burn the `tokens` portion
    /// @param _tokenId The token ID of the position
    function collectFees(uint256 _tokenId) external nonReentrant requireOwned(_tokenId) {
        // Require the caller to burn at least the minimum amount of `token`
        _burnTokensFrom(msg.sender, minTokenBurnAmount);

        // Collect the fees from the position
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        // Call DECREASE_LIQUIDITY with a liquidity of 0 to collect fees
        params[0] = abi.encode(_tokenId, 0, 0, 0, bytes(""));
        // Call TAKE_PAIR to close the open deltas and send the fees to the caller
        params[1] = abi.encode(token, currency, address(this));

        uint256 tokenBalanceBefore = Currency.wrap(token).balanceOfSelf();
        uint256 currencyBalanceBefore = Currency.wrap(currency).balanceOfSelf();
        // Set deadline to the current block
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);

        uint256 accruedTokenFees = Currency.wrap(token).balanceOfSelf() - tokenBalanceBefore;
        uint256 accruedCurrencyFees = Currency.wrap(currency).balanceOfSelf() - currencyBalanceBefore;

        // Burn the tokens from the collected fees
        _burnTokensFrom(address(this), accruedTokenFees);
        // Transfer the currency fees to the caller
        Currency.wrap(currency).transfer(msg.sender, accruedCurrencyFees);

        emit CurrencyFeesCollected(msg.sender, accruedCurrencyFees);
    }

    /// @notice Burns the tokens by transferring them to the burn address
    /// @dev Ensure that the `token` ERC20 contract allows transfers to address(0xdead)
    /// @param _amount The amount of tokens to burn
    function _burnTokensFrom(address _from, uint256 _amount) internal {
        if (_amount > 0) {
            if (_from == address(this)) {
                Currency.wrap(token).transfer(address(0xdead), _amount);
            } else {
                SafeTransferLib.safeTransferFrom(token, _from, address(0xdead), _amount);
            }
        }
        emit TokensBurned(_amount);
    }
}
