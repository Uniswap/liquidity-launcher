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
    /// @param migrationParams The migration parameters. Any nonzero migrationParams.hook MUST inherit InitializerHook.
    ///        If hook is address(0), migration uses the hookless pool unless it already exists, then falls back to
    ///        the LBPStrategy address as the hook.
    event InitializerCreated(ILBPInitializer indexed initializer, MigratorParameters migrationParams);

    /// @notice Emitted when tier-1 (`tryMigrate`) successfully migrates to the configured v4 pool.
    /// @param initializer The initializer that was migrated
    /// @param key The key of the pool that was created
    /// @param initialSqrtPriceX96 The initial sqrt price of the pool
    event Migrated(ILBPInitializer indexed initializer, PoolKey indexed key, uint160 initialSqrtPriceX96);

    /// @notice Emitted when the currency is swept
    event CurrencySwept(address indexed operator, uint256 amount);

    /// @notice Emitted when the tokens are swept
    event TokensSwept(address indexed operator, uint256 amount);

    /// @notice Emitted when tier-2 successfully mints a full-range position after the configured plan reverted.
    /// @param initializer The initializer that was fallback migrated
    /// @param key The pool key that received fallback liquidity
    /// @param initialSqrtPriceX96 The initial sqrt price of the pool
    /// @param currencyAmount The amount of currency consumed by the fallback LP position
    /// @param tokenAmount The amount of token consumed by the fallback LP position
    event FallbackMigrated(
        ILBPInitializer indexed initializer,
        PoolKey indexed key,
        uint160 initialSqrtPriceX96,
        uint256 currencyAmount,
        uint256 tokenAmount
    );

    /// @notice Emitted when tier-3 releases the strategy-held `supplyForLP` to `leftoverRecipient` after
    /// both migration attempts reverted. Any currency swept from the initializer in the
    /// same transaction is forwarded via the existing {CurrencySwept} event before this fires.
    /// @param initializer The initializer whose reserves were released
    /// @param recipient The configured `leftoverRecipient` that received the swept tokens
    /// @param amount The amount of `supplyForLP` transferred out of the strategy
    event FundsRecovered(ILBPInitializer indexed initializer, address indexed recipient, uint256 amount);

    /// @notice Error thrown when the initializer was already created
    /// @param initializer The initializer that has already been registered
    error InitializerAlreadyCreated(ILBPInitializer initializer);

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

    /// @notice Error thrown when the position recipient is the zero address, address(1), or address(2)
    /// @param positionRecipient The invalid position recipient
    error InvalidPositionRecipient(address positionRecipient);

    /// @notice Error thrown when the initializer's fundsRecipient is not the strategy
    /// @param actual The fundsRecipient configured on the initializer
    /// @param expected The required fundsRecipient (the strategy address)
    error InvalidFundsRecipient(address actual, address expected);

    /// @notice Error thrown when the initializer's tokensRecipient is the strategy
    /// (the strategy must never be the tokensRecipient — unsold auction tokens are claimed by the
    /// configured tokensRecipient directly from the initializer)
    /// @param actual The tokensRecipient configured on the initializer (always equal to the strategy when this fires)
    error InvalidTokensRecipient(address actual);

    /// @notice Error thrown when supplyForLP exceeds v4's int128 amount limit
    error InvalidSupplyForLp();

    /// @notice Error thrown when the currency swept from the initializer does not match the
    /// currencyRaised reported by the initializer's LBP parameters
    /// @param swept The amount of currency actually swept from the initializer
    /// @param claimed The currencyRaised value reported by the initializer
    error CurrencyRaisedMismatch(uint256 swept, uint256 claimed);

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

    /// @notice Error thrown when an initializer was never registered with the strategy
    /// @param initializer The initializer being acted on
    error InitializerNotRegistered(ILBPInitializer initializer);

    /// @notice Error thrown when an initializer's reserves were already consumed by a prior `migrate`.
    /// @param initializer The initializer being acted on
    error InsufficientReserves(ILBPInitializer initializer);

    /// @notice Error thrown when an internal try-function is invoked by anyone other than the strategy itself.
    error OnlySelfCall();

    /// @notice Migrates the raised funds and tokens to a v4 pool. Sole public entrypoint for terminating an
    /// initializer; internally waterfalls through three tiers, each invoked via an isolated self-call:
    ///        1. {tryMigrate} — configured-plan migration on the committed pool key.
    ///        2. {tryMigrate} — retry with the same `MigratorParameters`, except `positionDefinitions`
    ///           is replaced with a single full-range LP definition.
    ///        3. {_release} — sweep currency from the initializer and transfer the held `supplyForLP` plus
    ///           any swept currency to `leftoverRecipient`.
    /// @dev Tiers 2 and 3 are entered automatically when an earlier tier reverts. There is no separate
    ///      recovery entrypoint and no recovery delay. The terminal outcome is observable from exactly one of
    ///      {Migrated} (tier 1), {FallbackMigrated} (tier 2), or {FundsRecovered} (tier 3).
    /// @param initializer The initializer contract to seed the migration
    function migrate(ILBPInitializer initializer) external;

    /// @notice Returns the stored migration parameters for an initializer
    /// @param initializer The initializer to look up
    /// @return The stored MigratorParameters
    function initializers(ILBPInitializer initializer) external view returns (MigratorParameters memory);
}
