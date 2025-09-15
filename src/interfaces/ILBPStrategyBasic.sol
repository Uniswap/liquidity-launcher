// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IDistributionContract} from "./IDistributionContract.sol";

/// @title ILBPStrategyBasic
/// @notice Interface for the LBPStrategyBasic contract
interface ILBPStrategyBasic is IDistributionContract {
    /// @notice Emitted when the pool is initialized
    event Migrated(PoolKey indexed key, uint160 initialSqrtPriceX96);

    /// @notice Error thrown when migration to a v4 pool is not allowed yet
    error MigrationNotAllowed(uint256 migrationBlock, uint256 currentBlock);

    /// @notice Emitted when the tokens are swept
    event TokensSwept(address indexed operator, uint256 amount);

    /// @notice Emitted when the currency is swept
    event CurrencySwept(address indexed operator, uint256 amount);

    /// @notice Error thrown when the sweep block is before or at the migration block
    error InvalidSweepBlock(uint256 sweepBlock, uint256 migrationBlock);

    /// @notice Error thrown when the token split is too high
    error TokenSplitTooHigh(uint16 tokenSplit);

    /// @notice Error thrown when the tick spacing is greater than the max tick spacing or less than the min tick spacing
    error InvalidTickSpacing(int24 tickSpacing);

    /// @notice Error thrown when the fee is greater than the max fee
    error InvalidFee(uint24 fee);

    /// @notice Error thrown when the position recipient is the zero address, address(1), or address(2)
    error InvalidPositionRecipient(address positionRecipient);

    /// @notice Error thrown when the token and currency are the same
    error InvalidTokenAndCurrency(address token);

    /// @notice Error thrown when the liquidity is invalid
    error InvalidLiquidity(uint128 maxLiquidityPerTick, uint128 liquidity);

    /// @notice Error thrown when the caller is not the auction
    error NotAuction(address caller, address auction);

    /// @notice Error thrown when the caller is not the operator
    error NotOperator(address caller, address operator);

    /// @notice Error thrown when the sweep is not allowed yet
    error SweepNotAllowed(uint256 sweepBlock, uint256 currentBlock);

    /// @notice Error thrown when the token amount is invalid
    error InvalidTokenAmount(uint128 tokenAmount, uint128 reserveSupply);

    /// @notice Error thrown when the auction supply is zero
    error AuctionSupplyIsZero();

    /// @notice Error thrown when the currency amount is invalid
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
