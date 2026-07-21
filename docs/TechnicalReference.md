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
        - [AutoCompoundPositionRecipient](#autocompoundpositionrecipient)
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
The distribution system is modular, allowing different strategies to be implemented. The main class of strategies is `LBPStrategy` and its subclasses. At a high level, these contracts are responsible for the creation of a Continuous Clearing Auction, the initialization of a Uniswap V4 pool, and the migration of the liquidity to V4. `LBPStrategy.migrate()` is a one-shot action: if the internal migration attempt succeeds, liquidity is deployed to V4; if it reverts, the strategy immediately sweeps the held LP token reserves and any raised currency back to the initializer's configured `recipient`.

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

A deployed instance can be used as a `PositionDefinition.recipient` when using an LBPStrategy.

#### PositionFeesForwarder
The `PositionFeesForwarder` extends the `TimelockedPositionRecipient` contract and forwards all collected fees to a recipient.

#### BuybackAndBurnPositionRecipient
The `BuybackAndBurnPositionRecipient` extends the `TimelockedPositionRecipient` contract and facilitates burning the collected fees and tokens from the position.

#### AutoCompoundPositionRecipient
The `AutoCompoundPositionRecipient` extends the `TimelockedPositionRecipient` contract and is a singleton for arbitrary held v4 positions. It derives each position's pool currencies at compound time and pays the caller a configured share of freshly collected fees. Fees are only ever added to existing position liquidity.

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

After a configurable delay (`migrationBlock`), anyone can call `migrate()` to:

- Validate the initializer is registered, still has reserved LP tokens, and is past `migrationBlock`
- Initialize the Uniswap V4 pool at the discovered price
- Deploy liquidity according to the configured position definitions, plus an implicit full-range position minted from any leftover budget
- Transfer each LP NFT to its `PositionDefinition.overridePositionRecipient` when set, otherwise to `MigratorParameters.positionRecipient`. The full-range fallback position is always minted to `MigratorParameters.positionRecipient`

`migrate()` attempts the actual pool initialization and liquidity creation through an internal self-call. A successful migration consumes the initializer's reservation in the strategy (`reserves[initializer]` is zeroed), which permanently blocks any future `migrate` call for the same initializer.

A successful `migrate()` consumes the initializer's reservation in the strategy (`reserves[initializer]` is zeroed), which permanently blocks any future `migrate` or `recoverFunds` call for the same initializer.

**Note:** To optimize gas costs, any minimal dust amounts are foregone and locked in the PoolManager rather than being swept at the end of the migration process.

#### 5. Migration Failure and Recovery

If the internal migration attempt reverts after the initializer is eligible to migrate, `migrate()` catches the revert and treats the migration as terminal. It then:

- Sweeps any raised currency still held by the initializer to the strategy.
- Transfers the swept currency and the held `reservedTokenAmountForLP` to the initializer's configured `recipient`.
- Zeroes `reserves[initializer]`, which blocks any future migration attempt for the same initializer.
- Unsold auction tokens stay in the initializer and can be claimed through the initializer's own `tokensRecipient` path.

This behavior prevents funds from being stuck behind a migration path that is not expected to become valid later. Because each initializer's reserves are consumable exactly once, one initializer's failure recovery cannot reach into another initializer's held reserves on the same token.

#### 6. Ways Migration Can Fail

The strategy is written to make migration difficult to grief, but it cannot guarantee that every configured launch can create V4 liquidity. Users and integrators should treat migration safety as part of launch validation, especially when a launcher presents auctions as curated or safe.

The public `migrate()` call can still revert before attempting migration if the initializer is not registered, the reserved LP tokens were already consumed, or the current block is before `migrationBlock`. It can also revert during failure recovery if the strategy cannot sweep or transfer assets to the configured `recipient`.

Potential migration failure cases include:

- **Malicious or non-standard token:** The launched token can revert, return unexpected transfer behavior, block transfers to the PositionManager, or otherwise fail during LP funding or recovery. Fee-on-transfer and rebasing tokens are not supported and can also break accounting assumptions.
- **Malicious hook:** A configured V4 hook can revert during pool initialization or liquidity modification, or implement behavior that makes the committed pool unsafe for users. The strategy checks that nonzero migration hooks inherit `InitializerHook`, but that check does not prove the hook's economic behavior is safe.
- **Recipient unable to receive ETH:** If the raised currency is native ETH and the configured `recipient` rejects ETH, a successful migration can revert while sweeping leftovers, and a failed migration can also revert while trying to recover funds. In that case the public `migrate()` call reverts and the initializer remains pending until a later call can complete.
- **Position definitions that resolve to zero value:** Position definitions can resolve to no usable liquidity because of tiny budgets, extreme prices, tick rounding, or ranges that collapse after clamping to usable ticks. This can cause the position plan to create no meaningful LP, or cause the internal migration attempt to fail and trigger recovery.
- **Position definitions that cannot be created:** Position definitions can be syntactically valid at initialization but fail at migration time because the discovered price, tick spacing, max liquidity per tick, pool state, or PositionManager execution makes the final positions invalid or impossible to mint.
- **Overlapping snapped ranges that exceed per-tick liquidity:** Position planning caps liquidity per position, but not aggregate liquidity per tick. Multiple position definitions can snap to overlapping tick ranges, and their combined liquidity can exceed Uniswap V4's per-tick max liquidity during mint execution, causing migration to revert.

When the internal migration attempt fails and recovery succeeds, no V4 LP is created by the strategy; the raised currency and reserved LP tokens are returned to `recipient`. Users should validate the parameters set by the deployer before interacting with any strategies or associated contracts.

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
