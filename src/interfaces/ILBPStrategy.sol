// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IStrategy} from "./IStrategy.sol";
import {ILBPInitializer} from "./ILBPInitializer.sol";
import {MigratorParameters} from "../libraries/MigratorParams.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title ILBPStrategy
/// @notice Interface for the LBPStrategy contract
interface ILBPStrategy is IStrategy {
    /// @notice Emitted when the auction is initialized
    /// @param initializer The initializer contract that was created
    /// @param migrationParams The migration parameters. Any nonzero migrationParams.poolParameters.hook MUST inherit InitializerHook.
    ///        If hook is address(0), migration uses the hookless pool unless it already exists, then falls back to
    ///        the LBPStrategy address as the hook. address(0) is only valid with a static pool fee.
    event InitializerCreated(ILBPInitializer indexed initializer, MigratorParameters migrationParams);

    /// @notice Emitted when a v4 pool is created and the liquidity is migrated to it
    /// @param initializer The initializer that was migrated
    /// @param key The key of the pool that was created
    /// @param initialSqrtPriceX96 The initial sqrt price of the pool
    /// @param plan The PositionManager plan executed to mint the final positions
    event Migrated(ILBPInitializer indexed initializer, PoolKey indexed key, uint160 initialSqrtPriceX96, bytes plan);

    /// @notice Emitted when the currency is swept
    /// @param recipient The recipient that received the swept currency
    /// @param amount The amount of currency swept
    event CurrencySwept(address indexed recipient, uint256 amount);

    /// @notice Emitted when the tokens are swept
    /// @param recipient The recipient that received the swept tokens
    /// @param amount The amount of tokens swept
    event TokensSwept(address indexed recipient, uint256 amount);

    /// @notice Emitted when an initializer's held reservedTokenAmountForLP is recovered to its recipient. Recovery
    /// happens inline in the failure branch of `migrate()`, so the funds are returned in the same call that fails.
    /// @param initializer The initializer whose reserves were recovered
    /// @param recipient The recipient that received the recovered tokens
    /// @param amount The amount of reservedTokenAmountForLP transferred out of the strategy
    event FundsRecovered(ILBPInitializer indexed initializer, address indexed recipient, uint256 amount);

    /// @notice Emitted when a migration fails
    /// @param initializer The initializer that failed to migrate
    /// @param reason The reason the migration failed
    event MigrationFailed(ILBPInitializer indexed initializer, bytes reason);

    /// @notice Error thrown when the initializer was already created
    /// @param initializer The initializer that has already been registered
    error InitializerAlreadyCreated(ILBPInitializer initializer);

    /// @notice Error thrown when the hook is the strategy itself
    error HookIsStrategy();

    /// @notice Error thrown when the target poolId is already occupied or initialized
    /// @param poolId The pool id that is already occupied.
    /// @param initializer The initializer registered to the id. Returns address(0) if the pool is already initialized.
    error PoolIdOccupied(PoolId poolId, address initializer);

    /// @notice Error thrown when migration to a v4 pool is not allowed yet
    /// @param migrationBlock The block number at which migration is allowed
    /// @param currentBlock The current block number
    error MigrationNotYetAllowed(uint256 migrationBlock, uint256 currentBlock);

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

    /// @notice Error thrown when a position recipient is the zero address, address(1), or address(2)
    /// @param recipient The invalid position recipient
    error InvalidPositionRecipient(address recipient);

    /// @notice Error thrown when the recipient of unallocated currency is the zero address
    error InvalidRecipient();

    /// @notice Error thrown when the initializer's fundsRecipient is not the strategy
    /// @param actual The fundsRecipient configured on the initializer
    /// @param expected The required fundsRecipient (the strategy address)
    error InvalidFundsRecipient(address actual, address expected);

    /// @notice Error thrown when the initializer's tokensRecipient is the strategy
    /// (the strategy must never be the tokensRecipient — unsold auction tokens are claimed by the
    /// configured tokensRecipient directly from the initializer)
    /// @param actual The tokensRecipient configured on the initializer (always equal to the strategy when this fires)
    error InvalidTokensRecipient(address actual);

    /// @notice Error thrown when reservedTokenAmountForLP exceeds v4's int128 amount limit
    error InvalidReservedTokenAmountForLP();

    /// @notice Error thrown when the currency swept from the initializer does not match the
    /// currencyRaised reported by the initializer's LBP parameters
    /// @param swept The amount of currency actually swept from the initializer
    /// @param claimed The currencyRaised value reported by the initializer
    error CurrencyRaisedMismatch(uint256 swept, uint256 claimed);

    /// @notice Error thrown when the token is the zero address
    error ZeroAddressToken();

    /// @notice Error thrown when the three token sources disagree at registration.
    /// @param fromParam The function-param `token` (what the launcher is pulling)
    /// @param declared The user-declared MigratorParameters.token
    /// @param fromInitializer The initializer's own `token()` getter at registration
    error TokenMismatch(address fromParam, address declared, address fromInitializer);

    /// @notice Error thrown when the user-declared `MigratorParameters.currency` does not agree
    /// with the freshly deployed initializer's `currency()` getter at registration.
    /// @param declared The user-declared currency (from MigratorParameters.currency)
    /// @param fromInitializer The currency() value returned by the freshly deployed initializer
    error CurrencyMismatch(address declared, address fromInitializer);

    /// @notice Error thrown when the token amount mismatch after distribution
    /// @param actual The actual amount of token available after distribution
    /// @param expected The expected amount of token
    error TokenAmountMismatch(uint256 actual, uint256 expected);

    /// @notice Error thrown when an initializer was never registered with the strategy
    /// @param initializer The initializer being acted on
    error InitializerNotRegistered(ILBPInitializer initializer);

    /// @notice Error thrown when the function is called by an address other than the strategy
    error OnlySelfCall();

    /// @notice Error thrown when no positions are created during migration
    error NoPositionsCreated();

    /// @notice Migrates the raised funds and tokens to a v4 pool
    /// @dev Requires the initializer to be registered and have sufficient token reserves for migration
    /// @param initializer The initializer contract to seed the migration
    function migrate(ILBPInitializer initializer) external;

    /// @notice Returns the stored migration parameters for an initializer
    /// @param initializer The initializer to look up
    /// @return The stored MigratorParameters
    function initializers(ILBPInitializer initializer) external view returns (MigratorParameters memory);
}
