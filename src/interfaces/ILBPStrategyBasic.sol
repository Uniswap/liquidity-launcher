// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IDistributionContract} from "./IDistributionContract.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title ILBPStrategyBasic
/// @notice Interface for the LBPStrategyBasic contract
interface ILBPStrategyBasic is IDistributionContract {
    /// @notice Emitted when the pool is initialized
    event Migrated(PoolKey indexed key, uint160 initialSqrtPriceX96);

    /// @notice Emitted when the initial price is set
    event InitialPriceSet(uint160 sqrtPriceX96, uint256 tokenAmount, uint256 currencyAmount);

    /// @notice Error thrown when migration to a v4 pool is not allowed yet
    error MigrationNotAllowed();

    /// @notice Error thrown when caller is not the auction contract
    error OnlyAuctionCanSetPrice();

    /// @notice Error thrown when the currency amount transferred is invalid
    error InvalidCurrencyAmount();

    /// @notice Error thrown when ETH is sent to the contract but the configured currency is not ETH (e.g. an ERC20 token)
    error NonETHCurrencyCannotReceiveETH();

    /// @notice Error thrown when the token split is too high
    error TokenSplitTooHigh();

    /// @notice Error thrown when the tick spacing is greater than the max tick spacing or less than the min tick spacing
    error InvalidTickSpacing();

    /// @notice Error thrown when the fee is greater than the max fee
    error InvalidFee();

    /// @notice Error thrown when the position recipient is the zero address, address(1), or address(2)
    error InvalidPositionRecipient();

    /// @notice Error thrown when the position manager is the zero address
    error InvalidPositionManager();

    /// @notice Error thrown when the pool manager is the zero address
    error InvalidPoolManager();

    /// @notice Error thrown when the token and currency are the same
    error InvalidTokenAndCurrency();

    /// @notice Migrates the raised funds and tokens to a v4 pool
    function migrate() external;

    /// @notice Sets the initial price of the pool based on the auction results and transfers the currency to the contract
    /// @param sqrtPriceX96 The initial sqrt price of the pool
    /// @param tokenAmount The amount of tokens needed for that price
    /// @param currencyAmount The amount of currency needed for that price and transferred to the contract
    function setInitialPrice(uint160 sqrtPriceX96, uint256 tokenAmount, uint256 currencyAmount) external payable;
}
