// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IDistributionContract} from "./IDistributionContract.sol";

/// @title ILBPStrategyBasic
/// @notice Interface for the LBPStrategyBasic contract
interface ILBPStrategyBasic is IDistributionContract {
    /// @notice Emitted when a v4 pool is created and the liquidity is migrated to it
    /// @param key The key of the pool that was created
    /// @param initialSqrtPriceX96 The initial sqrt price of the pool
    event Migrated(PoolKey indexed key, uint160 initialSqrtPriceX96);

    /// @notice Emitted when the auction is created
    /// @param auction The address of the auction contract
    event AuctionCreated(address indexed auction);

    /// @notice Emitted when the pool is validated
    /// @param sqrtPriceX96 The sqrt price of the pool which will be used to initialize the pool
    /// @param tokenAmount The token amount which will be used to mint liquidity for the full range position
    /// @param currencyAmount The currency amount which will be used to mint liquidity for the full range position
    event Validated(uint160 sqrtPriceX96, uint128 tokenAmount, uint128 currencyAmount);

    /// @notice Error thrown when migration to a v4 pool is not allowed yet
    /// @param migrationBlock The block number at which migration is allowed
    /// @param currentBlock The current block number
    error MigrationNotAllowed(uint256 migrationBlock, uint256 currentBlock);

    /// @notice Emitted when the tokens are swept
    event TokensSwept(address indexed operator, uint256 amount);

    /// @notice Emitted when the currency is swept
    event CurrencySwept(address indexed operator, uint256 amount);

    /// @notice Error thrown when the sweep block is before or at the migration block
    error InvalidSweepBlock(uint256 sweepBlock, uint256 migrationBlock);

    /// @notice Error thrown when the token split is too high
    /// @param tokenSplit The invalid token split percentage
    error TokenSplitTooHigh(uint24 tokenSplit, uint24 maxTokenSplit);

    /// @notice Error thrown when the tick spacing is greater than the max tick spacing or less than the min tick spacing
    /// @param tickSpacing The invalid tick spacing
    error InvalidTickSpacing(int24 tickSpacing, int24 minTickSpacing, int24 maxTickSpacing);

    /// @notice Error thrown when the fee is greater than the max fee
    /// @param fee The invalid fee
    error InvalidFee(uint24 fee, uint24 maxFee);

    /// @notice Error thrown when the position recipient is the zero address, address(1), or address(2)
    /// @param positionRecipient The invalid position recipient
    error InvalidPositionRecipient(address positionRecipient);

    /// @notice Error thrown when the liquidity is invalid
    /// @param maxLiquidityPerTick The max liquidity per tick
    /// @param liquidity The invalid liquidity
    error InvalidLiquidity(uint128 maxLiquidityPerTick, uint128 liquidity);

    /// @notice Error thrown when the caller is not the auction
    /// @param caller The caller that is not the auction
    /// @param auction The auction that is not the caller
    error NotAuction(address caller, address auction);

    /// @notice Error thrown when the caller is not the operator
    error NotOperator(address caller, address operator);

    /// @notice Error thrown when the sweep is not allowed yet
    error SweepNotAllowed(uint256 sweepBlock, uint256 currentBlock);

    /// @notice Error thrown when the token amount is invalid
    /// @param tokenAmount The invalid token amount
    /// @param reserveSupply The reserve supply
    error InvalidTokenAmount(uint128 tokenAmount, uint128 reserveSupply);

    /// @notice Error thrown when the auction supply is zero
    error AuctionSupplyIsZero();

    /// @notice Error thrown when the currency amount is invalid
    /// @param currencyAmount The invalid currency amount
    /// @param balance The balance of the currency
    error InsufficientCurrency(uint128 currencyAmount, uint128 balance);

    /// @notice Migrates the raised funds and tokens to a v4 pool
    function migrate() external;

    /// @notice Allows the operator to sweep tokens from the contract
    /// @dev Can only be called after sweepBlock by the operator
    function sweepToken() external;

    /// @notice Allows the operator to sweep currency from the contract
    /// @dev Can only be called after sweepBlock by the operator
    function sweepCurrency() external;
}
