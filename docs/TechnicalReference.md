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

`distributeToken` hands off tokens already held by the launcher to a distribution strategy. The launcher approves the strategy and the strategy pulls via `safeTransferFrom` inside its own `initializeDistribution` (a pull-flow design). Token acquisition (`createToken` or `depositToken`) and `distributeToken` MUST be batched in the same `multicall`; tokens left in the launcher between transactions can be distributed by any caller.

### Token Factories

The system includes two token factory implementations:

#### UERC20Factory
Creates standard ERC20 tokens with extended metadata. These tokens support Permit2 by default and include on-chain metadata storage. The factory uses CREATE2 for deterministic addresses based on token parameters.

#### USUPERC20Factory
Extends the basic factory with superchain capabilities. Tokens deployed through this factory can be created on multiple chains with the same address, though only the home chain holds the initial supply. This enables seamless cross-chain token deployment while maintaining consistency across networks.

### Distribution Strategies
The distribution system is modular, allowing different strategies to be implemented. The main class of strategies is `LBPStrategy` and its subclasses. At a high level, these contracts are responsible for the creation of a Continuous Clearing Auction, the initialization of a Uniswap V4 pool, and the migration of the liquidity to V4. `LBPStrategy` also exposes a delayed `fallbackMigration` path: if `migrate` never fires, anyone may trigger one final full-range LP attempt after the configured delay past `migrationBlock`; only if that fallback cannot be executed are assets released to the initializer's `leftoverRecipient`.

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

Since LBPStrategies cannot control the final price of the Auction, or how much currency is raised, it is possible to configure an Auction such that it is impossible to migrate the liquidity to V4. Users should be aware that malicious deployers can design such parameters to eventually sweep the currency and tokens from the contract.

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
  `IInitializerHook` during `initializeDistribution`. If this field is `address(0)`, migration uses the hookless pool
  unless that pool already exists, in which case it uses `LBPStrategy` itself as the hook.
- **Auction Parameters**: Duration, pricing steps, and reserve price
- **LP Recipient**: Address that will receive the liquidity position NFT

#### 2. Auction Phase

The distribution strategy deploys an auction contract and transfers the allocated tokens. The auction runs according to the specified parameters, allowing users to bid for tokens at decreasing prices.

#### 3. Price Discovery Notification

Once the auction completes, it transfers the raised funds to the LBP Strategy and the strategy
grabs the final clearing price.

#### 4. Migration to Uniswap V4

After a configurable delay (`migrationBlock`), anyone can call `migrate()` to:

- Validate a v4 pool can be created
- Initialize the Uniswap V4 pool at the discovered price
- Deploy liquidity as a full-range position
- Create an optional one-sided position
- Transfer the LP NFT to the designated recipient

A successful `migrate()` consumes the initializer's reservation in the strategy (`reserves[initializer]` is zeroed), which permanently blocks any future `migrate` call for the same initializer.

**Note:** To optimize gas costs, any minimal dust amounts are foregone and locked in the PoolManager rather than being swept at the end of the migration process.

#### 5. Internal Fallback Waterfall

`migrate()` is the **sole public entrypoint** for terminating an initializer. There is no separate recovery function and no recovery delay. Internally `migrate()` waterfalls through three tiers in a single transaction; each tier is invoked via an external self-call so it has its own isolated state frame and its revert can be caught by the outer wrapper:

1. **Tier 1 — `tryMigrate`**: the configured-plan migration. Reads the auction's discovered price, initializes the committed pool (using `MigratorParameters.hook`, or the hookless / strategy-hook fallback per `_getPoolKey`), and executes the encoded `positionDefinitions` against the PositionManager. If anything reverts — bad price, currency mismatch, configured hook reverts, PositionManager rejects the plan — the outer `migrate` catches it and falls through.

2. **Tier 2 — `tryFallbackMigrate`**: a single full-range LP attempt on the **strategy-as-hook pool**, *ignoring* `MigratorParameters.hook`. Because `SelfInitializerMixin` reserves the strategy-hook pool key for the strategy's own initialization, no configured hook (buggy, paused, layout-specific, or adversarial) can block this pool. Tier 2 handles its own known failure modes (no currency raised, swept-vs-claimed mismatch, invalid price, no resolvable liquidity, pool already initialized, PositionManager revert) internally by releasing `supplyForLP` and the swept currency to `leftoverRecipient` and emitting `FallbackMigrationReleased` with a typed `FallbackReleaseReason`. The trade-off: fallback LP lands on a **different `PoolId`** than `migrate` would have produced. Only `tryFallbackMigrate`'s unexpected reverts (e.g. `initializer.sweepCurrency()` reverts) propagate to tier 3.

3. **Tier 3 — `_emergencyRelease`**: the final safety net. Reached only if `tryFallbackMigrate` itself reverts. Best-effort sweeps the initializer's currency, then releases whatever the strategy can move to `leftoverRecipient` and emits `FallbackMigrationReleased(reason = PositionManagerFailed)`. Funds are not permanently locked even if both prior tiers fail unexpectedly.

Outcomes are observable from three distinct events: `Migrated` (tier 1 success), `FallbackMigrated` (tier 2 success on the strategy-hook pool), or `FallbackMigrationReleased(reason)` (tier 2 or tier 3 release).

Because each initializer's reserves are consumable exactly once (by `migrate`), one initializer's release path cannot reach into another initializer's held reserves on the same token.

### LBP Hook Requirement

The `MigratorParameters.hook` field commits the exact Uniswap v4 hook used by the post-auction pool. Any nonzero hook configured in this field MUST inherit `InitializerHook`. `InitializerHook` enables the `BEFORE_INITIALIZE` permission, supports `IInitializerHook` via ERC165, and rejects pool initialization unless the PoolManager-reported sender is the singleton `LBPStrategy`. `LBPStrategy.initializeDistribution` checks this ERC165 support before storing the hook.

This requirement protects the committed pool from permissionless initialization at an arbitrary price. Hooks that do not inherit `InitializerHook` MUST NOT be used in `MigratorParameters.hook`. `GatedSwapHook` already inherits `InitializerHook` and satisfies this requirement.

`address(0)` is the only exception to the nonzero hook requirement. With `hook == address(0)`, migration first targets the hookless pool. If that pool is already initialized, `LBPStrategy` switches the pool key to `hooks = IHooks(address(this))` and initializes the strategy-hooked pool. The strategy therefore must be deployed at an address with the `BEFORE_INITIALIZE` hook permission bit, and its self-initializer only permits pool initialization when the PoolManager-reported sender is the strategy itself.

## Key Interfaces

**ILiquidityLauncher** defines the main launcher interface for creating and distributing tokens.

**IDistributionContract** implemented by contracts that receive and distribute tokens (e.g. the LBP initializer initializer). Exposes an `onTokensReceived()` hook that the parent strategy calls after pulling tokens into the contract — used by initializers to capture post-funding setup atomically with the pull.

**IDistributionStrategy** implemented by strategies that the launcher hands off to. The `initializeDistribution()` function is responsible for pulling `totalSupply` of `token` from `msg.sender` (the launcher) via `safeTransferFrom` — the launcher pre-approves the strategy for the full amount before invoking it. If a strategy or downstream factory uses deterministic deployment, it MUST include the provided `salt` in both deployment and address prediction calculations.

**ITokenFactory** defines the interface for token creation factories, standardizing how different token types are deployed.

## Important Safety Notes

⚠️ **Rebasing Tokens and Fee-on-Transfer Tokens are NOT compatible with LiquidityLauncher.** The system is designed for standard ERC20 tokens and will not function correctly with tokens that have dynamic balances or transfer fees.

⚠️ **Always batch token acquisition and distribution inside a single `multicall`.** The launcher uses a pull-based hand-off: tokens must already be in the launcher when `distributeToken` is called. If tokens sit in the launcher between transactions — for example, because you `createToken(recipient=launcher)` or `depositToken` in one tx and `distributeToken` in another — **any caller can call `distributeToken` on them with an arbitrary strategy and arbitrary parameters and steal them.** The supported flows are:

- **Fresh mint:** `createToken(recipient=address(launcher), ...) + distributeToken(...)` in one `multicall`.
- **Existing token:** `permit(...) (optional) + depositToken(...) + distributeToken(...)` in one `multicall`.

Anything else is unsafe.
