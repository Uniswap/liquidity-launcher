// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IDistributionContract} from "./IDistributionContract.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IContinuousClearingAuction} from "continuous-clearing-auction/src/interfaces/IContinuousClearingAuction.sol";

/// @title ILBPStrategyBase
/// @notice Base interface for derived LBPStrategy contracts
interface ILBPStrategyBase is IDistributionContract {
    /// @notice Emitted when a v4 pool is created and the liquidity is migrated to it
    /// @param key The key of the pool that was created
    /// @param initialSqrtPriceX96 The initial sqrt price of the pool
    event Migrated(PoolKey indexed key, uint160 initialSqrtPriceX96);

    /// @notice Emitted when the auction is created
    /// @param auction The address of the auction contract
    event AuctionCreated(address indexed auction);

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

    /// @notice Error thrown when the end block is at orafter the migration block
    /// @param endBlock The invalid end block
    /// @param migrationBlock The migration block
    error InvalidEndBlock(uint256 endBlock, uint256 migrationBlock);

    /// @notice Error thrown when the currency in the auction parameters is not the same as the currency in the migrator parameters
    /// @param auctionCurrency The currency in the auction parameters
    /// @param migratorCurrency The currency in the migrator parameters
    error InvalidCurrency(address auctionCurrency, address migratorCurrency);

    /// @notice Error thrown when the floor price is invalid
    /// @param floorPrice The invalid floor price
    error InvalidFloorPrice(uint256 floorPrice);

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

    /// @notice Error thrown when the funds recipient is not set to address(1)
    /// @param invalidFundsRecipient The invalid funds recipient
    /// @param expectedFundsRecipient The expected funds recipient (address(1))
    error InvalidFundsRecipient(address invalidFundsRecipient, address expectedFundsRecipient);

    /// @notice Error thrown when the reserve supply is too high
    /// @param reserveSupply The invalid reserve supply
    /// @param maxReserveSupply The maximum reserve supply (type(uint128).max)
    error ReserveSupplyIsTooHigh(uint256 reserveSupply, uint256 maxReserveSupply);

    /// @notice Error thrown when the liquidity is invalid
    /// @param liquidity The invalid liquidity
    /// @param maxLiquidity The max liquidity
    error InvalidLiquidity(uint128 liquidity, uint128 maxLiquidity);

    /// @notice Error thrown when the caller is not the auction
    /// @param caller The caller that is not the auction
    /// @param auction The auction that is not the caller
    error NativeCurrencyTransferNotFromAuction(address caller, address auction);

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

    /// @notice Error thrown when the currency amount is greater than type(uint128).max
    /// @param currencyAmount The invalid currency amount
    /// @param maxCurrencyAmount The maximum currency amount (type(uint128).max)
    error CurrencyAmountTooHigh(uint256 currencyAmount, uint256 maxCurrencyAmount);

    /// @notice Error thrown when the currency amount is invalid
    /// @param amountNeeded The currency amount needed
    /// @param amountAvailable The balance of the currency in the contract
    error InsufficientCurrency(uint256 amountNeeded, uint256 amountAvailable);

    /// @notice Error thrown when the auction has already been created
    error AuctionAlreadyCreated();

    /// @notice Error thrown when no currency was raised
    error NoCurrencyRaised();

    /// @notice Error thrown when the token amount is too high
    /// @param tokenAmount The invalid token amount
    error AmountOverflow(uint256 tokenAmount);

    /// @notice Migrates the raised funds and tokens to a v4 pool
    function migrate() external;

    /// @notice Allows the operator to sweep tokens from the contract
    /// @dev Can only be called after sweepBlock by the operator
    function sweepToken() external;

    /// @notice Allows the operator to sweep currency from the contract
    /// @dev Can only be called after sweepBlock by the operator
    function sweepCurrency() external;

    /// Getters
    function token() external view returns (address);
    function currency() external view returns (address);
    function totalSupply() external view returns (uint128);
    function reserveSupply() external view returns (uint128);
    function positionManager() external view returns (IPositionManager);
    function positionRecipient() external view returns (address);
    function migrationBlock() external view returns (uint64);
    function sweepBlock() external view returns (uint64);
    function operator() external view returns (address);
    function auction() external view returns (IContinuousClearingAuction);
    function auctionParameters() external view returns (bytes memory);
    function poolLPFee() external view returns (uint24);
    function poolTickSpacing() external view returns (int24);
    function maxCurrencyAmountForLP() external view returns (uint128);
}
