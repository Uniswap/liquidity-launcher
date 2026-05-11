// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IDistributionContract} from "./IDistributionContract.sol";
import {IDistributionStrategy} from "./IDistributionStrategy.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {ILBPInitializer} from "./ILBPInitializer.sol";
import {MigratorParameters, LiquidityAllocationBracket} from "../libraries/MigratorParams.sol";

/// @title ILBPStrategy
/// @notice Interface for the LBPStrategy contract
interface ILBPStrategy is IDistributionStrategy {
    /// @notice Emitted when the auction is initialized
    /// @param initializer The initializer contract that was created
    /// @param migrationParams The migration parameters
    event InitializerCreated(ILBPInitializer indexed initializer, MigratorParameters migrationParams);

    /// @notice Emitted when a v4 pool is created and the liquidity is migrated to it
    /// @param initializer The initializer that was migrated
    /// @param key The key of the pool that was created
    /// @param initialSqrtPriceX96 The initial sqrt price of the pool
    event Migrated(ILBPInitializer indexed initializer, PoolKey indexed key, uint160 initialSqrtPriceX96);

    /// @notice Emitted when the currency is swept
    event CurrencySwept(address indexed operator, uint256 amount);

    /// @notice Emitted when the tokens are swept
    event TokensSwept(address indexed operator, uint256 amount);

    /// @notice Emitted when the protocol fee controller is set
    /// @param protocolFeeController The protocol fee controller
    event ProtocolFeeControllerSet(address protocolFeeController);

    /// @notice Error thrown when the initializer was already created
    /// @param initializer The initializer that has already been registered
    error InitializerAlreadyCreated(ILBPInitializer initializer);

    /// @notice Error thrown when migration to a v4 pool is not allowed yet
    /// @param migrationBlock The block number at which migration is allowed
    /// @param currentBlock The current block number
    error MigrationNotAllowed(uint256 migrationBlock, uint256 currentBlock);

    /// @notice Error thrown when the end block is at or after the migration block
    /// @param endBlock The invalid end block
    /// @param migrationBlock The migration block
    error InvalidEndBlock(uint256 endBlock, uint256 migrationBlock);

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

    /// @notice Error thrown when the CCA's custody tokens do not match the expected supplyForLP
    /// @param custodyTokens The CCA's reported custody tokens
    /// @param expectedCustodyTokens The expected custody tokens (supplyForLP)
    error InvalidCustodySupply(uint256 custodyTokens, uint256 expectedCustodyTokens);

    /// @notice Error thrown when supplyForLP exceeds v4's int128 amount limit
    /// @param supplyForLP The invalid supply
    /// @param maxSupplyForLP The max supply (uint128(type(int128).max))
    error InvalidSupplyForLp(uint128 supplyForLP, uint128 maxSupplyForLP);

    /// @notice Error thrown when no currency was raised
    error NoCurrencyRaised();

    /// @notice Migrates the raised funds and tokens to a v4 pool
    /// @param initializer The initializer contract that was created
    function migrate(ILBPInitializer initializer) external;

    /// @notice Returns the stored migration parameters for an initializer
    /// @param initializer The initializer to look up
    /// @return The stored MigratorParameters
    function initializers(ILBPInitializer initializer) external view returns (MigratorParameters memory);

    /// @notice Sets the protocol fee controller
    /// @param protocolFeeController The protocol fee controller
    function setProtocolFeeController(address protocolFeeController) external;
}
