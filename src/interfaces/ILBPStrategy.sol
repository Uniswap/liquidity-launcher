// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IDistributionContract} from "./IDistributionContract.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {ILBPInitializer} from "./ILBPInitializer.sol";
import {AuctionParameters} from "continuous-clearing-auction/src/interfaces/IContinuousClearingAuction.sol";

/// @title ILBPStrategy
/// @notice Interface for the LBPStrategy contract
interface ILBPStrategy {
    // TODO: Replace with AuctionParameters from continuous-clearing-auction once the changes are implemented
    struct AuctionParameters {
        address currency; // token to raise funds in. Use address(0) for ETH
        uint128 custodyTokens; // amount of tokens to be held in custody during the auction
        address tokensRecipient; // address to receive leftover tokens
        address fundsRecipient; // address to receive all raised funds
        uint64 startBlock; // Block which the first step starts
        uint64 endBlock; // When the auction finishes
        uint64 claimBlock; // Block when the auction can claimed
        uint256 tickSpacing; // Fixed granularity for prices
        address validationHook; // Optional hook called before a bid
        uint256 floorPrice; // Starting floor price for the auction
        uint128 requiredCurrencyRaised; // Amount of currency required to be raised for the auction to graduate
        bytes auctionStepsData; // Packed bytes describing token issuance schedule
    }

    struct MigratorParameters {
        uint64 migrationBlock; // block number when the migration can begin
        uint24 poolLPFee; // the LP fee that the v4 pool will use
        int24 poolTickSpacing; // the tick spacing that the v4 pool will use
        uint128 supplyForLP; // additional amount of the token that will be used to create the LP position
        address fundsRecipient; // the address that will receive the funds from the auction
        uint128 custodyTokens; // additional amount of the token that will be hold in custody during the auction (additionally to supplyForLP)
        address lpPositionRecipient; // the address that will receive the created LP position
        uint24 currencySplitForLP; // the percentage of the currency that will be used for LP, expressed in mps (1e7 = 100%)
        address lpHook; // the hook that will be used to initialize the pool
    }

    struct MigrationData {
        uint160 sqrtPriceX96;
        uint128 fullRangeTokenAmount;
        uint128 fullRangeCurrencyAmount;
        uint128 leftoverToken;
        uint128 leftoverCurrency;
        uint128 liquidity;
    }

    /// @notice Emitted when the settings are set
    /// @param protocolFeeController The protocol fee controller
    /// @param minSplitForLP The min split for LP
    event SettingsSet(address protocolFeeController, uint24 minSplitForLP);

    /// @notice Emitted when the auction is initialized
    /// @param initializer The initializer contract that was created
    /// @param migrationParams The migration parameters
    event InitializerCreated(ILBPInitializer indexed initializer, MigratorParameters migrationParams);

    /// @notice Emitted when a v4 pool is created and the liquidity is migrated to it
    /// @param key The key of the pool that was created
    /// @param initialSqrtPriceX96 The initial sqrt price of the pool
    event Migrated(PoolKey indexed key, uint160 initialSqrtPriceX96);

    /// @notice Emitted when the currency is swept
    event CurrencySwept(address indexed operator, uint256 amount);

    /// @notice Emitted when the tokens are swept
    event TokensSwept(address indexed operator, uint256 amount);

    /// @notice Error thrown when migration to a v4 pool is not allowed yet
    /// @param migrationBlock The block number at which migration is allowed
    /// @param currentBlock The current block number
    error MigrationNotAllowed(uint256 migrationBlock, uint256 currentBlock);

    /// @notice Error thrown when the end block is at orafter the migration block
    /// @param endBlock The invalid end block
    /// @param migrationBlock The migration block
    error InvalidEndBlock(uint256 endBlock, uint256 migrationBlock);

    /// @notice Error thrown when the currency split for LP is smaller than the min split for LP or bigger than 100%
    /// @param currencySplitForLP The invalid currency split for LP
    /// @param minSplitForLP The min split for LP
    /// @param maxSplitForLP The max split for LP
    error InvalidCurrencySplitForLP(uint24 currencySplitForLP, uint24 minSplitForLP, uint24 maxSplitForLP);

    /// @notice Error thrown when the tick spacing is greater than the max tick spacing or less than the min tick spacing
    /// @param tickSpacing The invalid tick spacing
    error InvalidTickSpacing(int24 tickSpacing, int24 minTickSpacing, int24 maxTickSpacing);

    /// @notice Error thrown when the fee is greater than the max fee
    /// @param fee The invalid fee
    error InvalidFee(uint24 fee, uint24 maxFee);

    /// @notice Error thrown when the position recipient is the zero address, address(1), or address(2)
    /// @param positionRecipient The invalid position recipient
    error InvalidPositionRecipient(address positionRecipient);

    /// @notice Error thrown when the funds recipient is not set to the strategy
    /// @param expectedRecipient The expected recipient
    error InvalidRecipient(address expectedRecipient);

    /// @notice Error thrown when the currency amount is greater than type(uint128).max
    /// @param currencyAmount The invalid currency amount
    /// @param maxCurrencyAmount The maximum currency amount (type(uint128).max)
    error CurrencyAmountTooHigh(uint256 currencyAmount, uint256 maxCurrencyAmount);

    /// @notice Error thrown when no currency was raised
    error NoCurrencyRaised();

    /// @notice Error thrown when the migration parameters provided differ from the original ones
    error InvalidMigrationParameters();

    /// @notice Migrates the raised funds and tokens to a v4 pool
    function migrate(ILBPInitializer initializer, MigratorParameters calldata migrationParams) external;
}
