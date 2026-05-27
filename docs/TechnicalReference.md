# Technical Reference

## Table of Contents
- [Core Components](#core-components)
    - [LiquidityLauncher](#liquiditylauncher)
    - [Token Factories](#token-factories)
        - [UERC20Factory](#uerc20factory)
        - [USUPERC20Factory](#usuperc20factory)
    - [Distribution Strategies](#distribution-strategies)
        - [FullRangeLBPStrategy](#fullrangelbpstrategy)
        - [AdvancedLBPStrategy](#advancedlbpstrategy)
        - [GovernedLBPStrategy](#governedlbpstrategy)
        - [VirtualLBPStrategy](#virtuallbpstrategy)
    - [Warnings](#warnings)
    - [Periphery contracts](#periphery-contracts)
        - [TimelockedPositionRecipient](#timelockedpositionrecipient)
        - [PositionFeesForwarder](#positionfeesforwarder)
        - [BuybackAndBurnPositionRecipient](#buybackandburnpositionrecipient)
- [Contract Interactions](#contract-interactions)
- [Key Interfaces](#key-interfaces)
- [Important Safety Notes](#important-safety-notes)

## Core Components

### LiquidityLauncher

The main entry point contract that orchestrates token creation and distribution. It provides three primary functions:

`createToken` deploys a new token through a specified factory contract. The launcher supports different token standards including basic ERC20 tokens (UERC20) and Superchain tokens (USUPERC20) that can be deployed deterministically. Tokens are created with metadata support including description, website, and image URIs.

`depositToken` pulls an existing ERC20 balance from `msg.sender` into the launcher via Permit2. Used for the "distribute a token I already hold" flow; the caller must have a Permit2 allowance for the launcher (set in a prior tx or via `permit(...)` earlier in the same multicall).

`distributeToken` hands off tokens already held by the launcher to a strategy. The launcher approves the strategy and the strategy pulls via `safeTransferFrom` inside its own `initializeDistribution` (a pull-flow design). Token acquisition (`createToken` or `depositToken`) and `distributeToken` MUST be batched in the same `multicall`; tokens left in the launcher between transactions can be distributed by any caller.

### Token Factories

The system includes two token factory implementations:

#### UERC20Factory
Creates standard ERC20 tokens with extended metadata. These tokens support Permit2 by default and include on-chain metadata storage. The factory uses CREATE2 for deterministic addresses based on token parameters.

#### USUPERC20Factory
Extends the basic factory with superchain capabilities. Tokens deployed through this factory can be created on multiple chains with the same address, though only the home chain holds the initial supply. This enables seamless cross-chain token deployment while maintaining consistency across networks.

### Distribution Strategies
The distribution system is modular, allowing different strategies to be implemented. The main class of strategies is `LBPStrategy` and its subclasses. At a high level, these contracts are responsible for the creation of a Continuous Clearing Auction, the initialization of a Uniswap V4 pool, and the migration of the liquidity to V4. `migrate()` is the only public terminal path for an LBP initializer: it first attempts the configured migration, then attempts a full-range fallback migration, then releases assets to the configured `recipient` if liquidity cannot be created.

They all inherit from the `LBPStrategyBase` contract, which provides the core functionality for the strategy.

#### FullRangeLBPStrategy
A simple implementation that migrates raised funds to Uniswap V4 as a single full-range position. It is the simplest strategy and is suitable for most use cases.

#### AdvancedLBPStrategy
A more advanced strategy that uses any excess tokens or currency after the full-range position is created to seed one-sided positions.

#### GovernedLBPStrategy
A strategy that lets a trusted entity restrict swapping on the liquidity pool.

#### VirtualLBPStrategy
A strategy that implements a virtual token backed by an underlying token. This is useful for tokens with complex vesting or lockup schedules.

All of the above strategies are provided as-is, and custom strategies can be implemented by extending the `LBPStrategyBase` contract.

### Warnings

Users should be aware that it is trivially easy to create a LBPStrategy and corresponding Auction with malicious parameters. This can lead to a loss of funds or a degraded experience. You must validate all parameters set on each contract in the system before interacting with them.

Since LBPStrategies cannot control the final price of the Auction, or how much currency is raised, it is possible to configure an Auction such that it is impossible to migrate the liquidity to V4. Users should be aware that malicious deployers can design such parameters so a failed migration returns the raised currency and reserved LP tokens to the configured `recipient` instead of creating the expected V4 liquidity.

We strongly recommend that a token with value such as ETH or USDC is used as the `currency`.

### Periphery contracts
The following periphery contracts are provided as examples.

#### TimelockedPositionRecipient
The `TimelockedPositionRecipient` contract is a utility contract for holding a v4 LP position until a timelock period has passed. It is used to ensure that the position is not transferred to the recipient before the timelock expires.

A deployed instance can be used as the `positionRecipient` when using an LBPStrategy.

#### PositionFeesForwarder
The `PositionFeesForwarder` extends the `TimelockedPositionRecipient` contract and forwards all collected fees to a recipient.

#### BuybackAndBurnPositionRecipient
The `BuybackAndBurnPositionRecipient` extends the `TimelockedPositionRecipient` contract and facilitates burning the collected fees and tokens from the position.

## Contract Interactions

### Typical Launch Flow

The typical flow for launching a token involves several coordinated steps:

#### 1. Token Creation and Distribution

Use `LiquidityLauncher.multicall` to atomically batch token acquisition with `distributeToken`. Two supported flows:

- **Fresh mint:** `createToken(recipient=address(launcher), ...)` + `distributeToken(...)` — the factory mints directly into the launcher.
- **Existing token:** `permit(...)` (optional, if no active Permit2 allowance) + `depositToken(token, amount)` + `distributeToken(...)` — pulls the caller's tokens into the launcher via Permit2.

Either way, the strategy then pulls the tokens out of the launcher via `safeTransferFrom` inside its own `initializeDistribution`.

For the LBP strategy, the distribution configuration includes:

- **Allocation Split**: Division between auction and liquidity reserves
- **Pool Parameters**: Fee tier and tick spacing for the Uniswap V4 pool
- **Hook**: Optional Uniswap v4 hook address. Any hook used in the `hook` field MUST inherit `InitializerHook`
  so `beforeInitialize` restricts pool initialization to the LBP strategy. The strategy checks ERC165 support for
  `IInitializerHook` during `initializeDistribution`. If this field is `address(0)`, static-fee migration uses the
  hookless pool unless that pool already exists, in which case it uses `LBPStrategy` itself as the hook. Dynamic-fee
  pools must provide a nonzero hook with the fee logic.
- **Auction Parameters**: Duration, pricing steps, and reserve price
- **LP Recipient**: Address that will receive the liquidity position NFT

#### 2. Auction Phase

The strategy deploys an auction contract and transfers the allocated tokens. The auction runs according to the specified parameters, allowing users to bid for tokens at decreasing prices.

#### 3. Price Discovery Notification

Once the auction completes, it transfers the raised funds to the LBP Strategy and the strategy
grabs the final clearing price.

#### 4. Migration to Uniswap V4

After `migrationBlock`, anyone can call `migrate()` for a registered initializer that still has reserved LP tokens. There is no separate recovery function and no recovery delay. A terminal `migrate()` call consumes `reserves[initializer]` exactly once, which prevents later migration attempts for the same initializer and prevents one initializer's release path from using another initializer's reserves.

`migrate()` runs an atomic three-tier waterfall:

1. **Configured migration:** `tryMigrate` initializes the selected V4 pool at the auction's discovered price and executes the configured `positionDefinitions` against the PositionManager. The pool uses `MigratorParameters.poolParameters.hook`; if the hook is `address(0)` and the hookless static-fee pool already exists, the strategy falls back to its own hook address for pool initialization.
2. **Full-range fallback:** if the configured migration reverts, `tryFallbackMigrate` retries with the same migration parameters, discovered price, pool selection logic, and LP allocation schedule, but replaces the configured position plan with one full-range position.
3. **Release:** if the fallback migration also reverts, `_release` transfers the swept auction currency and reserved LP token supply to the initializer's configured `recipient`.

Outcomes are observable from `Migrated`, `FallbackMigrated`, or `FundsRecovered`. On a successful LP-creating tier, the strategy sweeps unused raised currency and unused reserved LP tokens to `recipient`; unsold auction tokens remain in the initializer and are claimed through the initializer's `tokensRecipient` path. To optimize gas costs, minimal dust amounts can be left in the PoolManager instead of being swept at the end of migration.

#### 5. Migration Caveats

The strategy is written to avoid stuck reserves, but it cannot guarantee that every launch can create V4 liquidity. Users and integrators should validate launch parameters before treating an auction as curated or safe.

The public `migrate()` call reverts before the waterfall if the initializer is not registered, the initializer's reserves were already consumed, or the current block is before `migrationBlock`. If a later transfer or release reverts, the entire transaction reverts and state rolls back, so the initializer remains pending and can be retried.

Potential migration failure cases include:

- **Initializer sweep failure:** migration relies on the initializer's `sweepCurrency()` not reverting. If the initializer cannot sweep raised currency to the strategy, the migration tiers cannot use that currency and release can only move assets already held by the strategy.
- **Swept-vs-reported mismatch:** the currency swept from the initializer must equal the initializer's reported `currencyRaised`; otherwise both LP-creation tiers revert and the flow falls through to release.
- **Invalid or extreme price:** a zero, overflowing, or otherwise unusable discovered price can prevent pool initialization or position planning.
- **Malicious or non-standard token:** the launched token can revert, return unexpected transfer behavior, block transfers to the PositionManager, or fail during release. Fee-on-transfer and rebasing tokens are not supported and can break accounting assumptions.
- **Hook failure:** a configured V4 hook can revert during pool initialization or liquidity modification, or implement unsafe economic behavior. The strategy checks that nonzero migration hooks inherit `InitializerHook`, but that check does not prove the hook is safe.
- **Recipient unable to receive assets:** if the `recipient` rejects ETH or a token transfer fails, successful-migration leftover sweeps or failure release can revert. In that case the `migrate()` transaction rolls back and remains retryable.
- **No resolvable liquidity:** position definitions can resolve to no usable positions because of tiny budgets, extreme prices, tick rounding, or ranges that collapse after clamping to usable ticks. The configured tier then falls through to the full-range fallback.
- **Unmintable liquidity:** syntactically valid position definitions can still fail at migration time because of the final price, tick spacing, max liquidity per tick, existing pool state, or PositionManager execution.
- **Aggregate tick liquidity:** planning caps liquidity per position, but not aggregate liquidity per tick. Multiple positions can snap to overlapping tick ranges and exceed Uniswap V4's per-tick max liquidity during mint execution.

When both LP-creation tiers fail and release succeeds, no V4 LP is created by the strategy. The swept auction currency and reserved LP tokens are returned to `recipient`, and the initializer's reserve is consumed.

### LBP Hook Requirement

The `MigratorParameters.poolParameters.hook` field commits the exact Uniswap v4 hook used by the post-auction pool. Any nonzero hook configured in this field MUST inherit `InitializerHook`. `InitializerHook` enables the `BEFORE_INITIALIZE` permission, supports `IInitializerHook` via ERC165, and rejects pool initialization unless the PoolManager-reported sender is the singleton `LBPStrategy`. `LBPStrategy.initializeDistribution` checks this ERC165 support before storing the hook.

This requirement protects the committed pool from permissionless initialization at an arbitrary price. Hooks that do not inherit `InitializerHook` MUST NOT be used in `MigratorParameters.poolParameters.hook`. `GatedSwapHook` already inherits `InitializerHook` and satisfies this requirement.

`address(0)` is the only exception to the nonzero hook requirement for static-fee pools. With `hook == address(0)`, migration first targets the hookless pool. If that pool is already initialized, `LBPStrategy` switches the pool key to `hooks = IHooks(address(this))` and initializes the strategy-hooked pool. The strategy therefore must be deployed at an address with the `BEFORE_INITIALIZE` hook permission bit, and its self-initializer only permits pool initialization when the PoolManager-reported sender is the strategy itself. Dynamic-fee pools must configure a nonzero hook because `LBPStrategy` does not implement dynamic fee updates.

## Key Interfaces

**ILiquidityLauncher** defines the main launcher interface for creating and distributing tokens.

**IDistributor** implemented by contracts that receive and distribute tokens (e.g. the LBP initializer). Distributors use a push based token model: the caller sends token funds to the distributor, then MUST call `onTokensReceived()` after funding so the distributor can capture post-funding setup atomically.

**IStrategy** implemented by strategies that the launcher hands off to. The `initializeDistribution()` function is responsible for pulling `totalSupply` of `token` from `msg.sender` (the launcher) via `safeTransferFrom` — the launcher pre-approves the strategy for the full amount before invoking it. The function does not return a downstream distributor; `Distribution.strategy` is the token-pulling strategy, and strategy-specific events or prediction helpers expose any child contracts.

**IDistributorFactory** implemented by factories that parent strategies use when they need a created distributor address, such as the LBP strategy's initializer factory. This minimal factory interface exposes `create(...)` and `getAddress(...)`; it does not fund the distributor, so the calling strategy remains responsible for token movement and `onTokensReceived()`.

**ITokenFactory** defines the interface for token creation factories, standardizing how different token types are deployed.

## Important Safety Notes

⚠️ **Rebasing Tokens and Fee-on-Transfer Tokens are NOT compatible with LiquidityLauncher.** The system is designed for standard ERC20 tokens and will not function correctly with tokens that have dynamic balances or transfer fees.

⚠️ **Always batch token acquisition and distribution inside a single `multicall`.** The launcher uses a pull-based hand-off: tokens must already be in the launcher when `distributeToken` is called. If tokens sit in the launcher between transactions — for example, because you `createToken(recipient=launcher)` or `depositToken` in one tx and `distributeToken` in another — **any caller can call `distributeToken` on them with an arbitrary strategy and arbitrary parameters and steal them.** The supported flows are:

- **Fresh mint:** `createToken(recipient=address(launcher), ...) + distributeToken(...)` in one `multicall`.
- **Existing token:** `permit(...) (optional) + depositToken(...) + distributeToken(...)` in one `multicall`.

Anything else is unsafe.
