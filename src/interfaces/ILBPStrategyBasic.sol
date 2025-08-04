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

    /// @notice Migrates the raised funds and tokens to a v4 pool
    function migrate() external;

    /// @notice Sets the initial price of the pool based on the auction results
    /// @param initialSqrtPriceX96 The initial sqrt price of the pool
    /// @param initialTokenAmount The amount of tokens needed for that price
    function setInitialPrice(uint160 initialSqrtPriceX96, uint256 initialTokenAmount) external payable;
}
