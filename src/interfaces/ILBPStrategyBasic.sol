// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IDistributionContract} from "./IDistributionContract.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title ILBPStrategyBasic
/// @notice Interface for the LBPStrategyBasic contract
interface ILBPStrategyBasic is IDistributionContract {
    /// @notice Emitted when the pool is initialized
    event Migrated(PoolKey indexed key, uint160 initialSqrtPriceX96);

    /// @notice Error thrown when migration to a v4 pool is not allowed yet
    error MigrationNotAllowed(uint256 migrationBlock, uint256 currentBlock);

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

    /// @notice Error thrown when the price is invalid
    error InvalidPrice(uint256 price);

    /// @notice Error thrown when the liquidity is invalid
    error InvalidLiquidity(uint128 maxLiquidityPerTick, uint128 liquidity);

    /// @notice Error thrown when the auction is not ended
    error AuctionNotEnded(uint256 endBlock, uint256 currentBlock);

    /// @notice Error thrown when the token amount is invalid
    error InvalidTokenAmount(uint128 tokenAmount, uint128 reserveSupply);

    /// @notice Error thrown when the auction supply is zero
    error AuctionSupplyIsZero();

    /// @notice Migrates the raised funds and tokens to a v4 pool
    function migrate() external;

    /// @notice Fetches the price and currency from the auction
    function fetchPriceAndCurrencyFromAuction() external;
}
