// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title ISubscriber
/// @notice Interface for the Subscriber contract
interface ISubscriber {
    /// @notice Emitted when being notified of the final price
    event Notified(bytes data);

    /// @notice Error thrown when caller is not the auction contract
    error OnlyAuctionCanSetPrice(address auction, address caller);

    /// @notice Error thrown when the currency amount transferred is invalid
    error InvalidCurrencyAmount(uint256 expected, uint256 received);

    /// @notice Error thrown when ETH is sent to the contract but the configured currency is not ETH (e.g. an ERC20 token)
    error NonETHCurrencyCannotReceiveETH(address currency);

    /// @notice Error thrown when the price is invalid
    error InvalidPrice(uint256 price);

    /// @notice Error thrown when the liquidity is invalid
    error InvalidLiquidity(uint128 maxLiquidityPerTick, uint128 liquidity);

    /// @notice Error thrown when the token amount is invalid
    error InvalidTokenAmount(uint128 tokenAmount, uint128 reserveSupply);

    /// @notice Called when being notified of the final price
    /// @param data The data to be passed to the subscriber regarding the initial price
    function onNotify(bytes memory data) external payable;
}
