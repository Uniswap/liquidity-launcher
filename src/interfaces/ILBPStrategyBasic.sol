// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IDistributionContract} from "./IDistributionContract.sol";

/// @title ILBPStrategyBasic
/// @notice Interface for the LBPStrategyBasic contract
interface ILBPStrategyBasic is IDistributionContract {
    /// @notice Error thrown when migration to a v4 poolis not allowed yet
    error MigrationNotAllowed();

    /// @notice Error thrown when caller is not the auction contract
    error OnlyAuctionCanSetPrice();

    /// @notice Error thrown when the currency amount transferred is invalid
    error InvalidCurrencyAmount();

    /// @notice Migrates the raised funds and tokens to a v4 pool
    function migrate() external;

    /// @notice Sets the initial price of the pool based on the auction results and transfers the currency to the contract
    /// @param sqrtPriceX96 The initial sqrt price of the pool
    /// @param tokenAmount The amount of tokens needed for that price
    /// @param currencyAmount The amount of currency needed for that price and transferred to the contract
    function setInitialPrice(uint160 sqrtPriceX96, uint256 tokenAmount, uint256 currencyAmount) external payable;
}
