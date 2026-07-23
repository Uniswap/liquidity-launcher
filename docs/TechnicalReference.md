# Technical Reference

## Table of Contents
- [Core Components](#core-components)
    - [LiquidityLauncher](#liquiditylauncher)
    - [Token Factories](#token-factories)
        - [UERC20Factory](#uerc20factory)
        - [USUPERC20Factory](#usuperc20factory)
    - [Distribution Strategies](#distribution-strategies)
        - [DirectLaunchStrategy](#directlaunchstrategy)
        - [FullRangeLBPStrategy](#fullrangelbpstrategy)
        - [AdvancedLBPStrategy](#advancedlbpstrategy)
        - [GovernedLBPStrategy](#governedlbpstrategy)
        - [VirtualLBPStrategy](#virtuallbpstrategy)
    - [Warnings](#warnings)
    - [Periphery contracts](#periphery-contracts)
        - [TimelockedPositionRecipient](#timelockedpositionrecipient)
        - [FeeSplitter](#feesplitter)
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
The distribution system is modular and supports direct-to-pool launches and auction-based launches.

#### DirectLaunchStrategy

`DirectLaunchStrategy` creates a v4 pool and token-side LP positions in one call. It has no auction or graduation step. The caller approves `totalSupply`, then calls `initializeDistribution` with ABI-encoded `DirectLaunchParameters`. The strategy pulls the tokens, registers any launch-hook configuration, initializes the pool, and mints the positions.

The caller configures:

- The paired currency, initial price, fee, tick spacing, and hook.
- Weighted `PositionDefinition[]` data. Weights MUST total `1e7`, and every resolved range MUST be entirely on the token side of the initial price.
- The LP NFT recipient and optional per-position recipient overrides.
- A recipient for rounding dust and tokens that cannot be placed because of per-tick liquidity limits.
- Optional `LaunchConfig` data when the hook implements `ILaunchHook`.

The launched token MUST be a standard ERC20, MUST differ from the paired currency, and MUST transfer exactly `totalSupply`. Fee-on-transfer and rebasing tokens are not supported. Position definitions allocate the full token budget, but the strategy does not guarantee that all tokens become liquidity: rounding and v4 liquidity limits can leave tokens for the configured sweep recipient. LP NFTs are owned and controlled by their configured recipients.

Hooks are trusted launch inputs. Every direct launch MUST configure an `IInitializerHook` that authorizes the calling strategy and has the required v4 permission bits. This gate prevents third parties from initializing the configured pool key first. An `ILaunchHook` also requires a nonempty `LaunchConfig`; other hooks reject launch configuration. `DirectLaunchStrategy` derives the token's currency ordering and overwrites `LaunchConfig.tokenIsCurrency0` before registration.

`DirectLaunchStrategy` is inheritable. Derived strategies can reuse exact token intake and the full launch sequence, or override launch, position-planning, hook-registration, and sweep steps when their constraints allow a smaller implementation.

`LaunchHook` restricts initialization to the strategy, rejects static-fee pools, blocks swaps before `swapStartBlock`, and applies `baseFee` at or after `windowEndBlock`. During the launch window, it uses the configured `IDynamicFeeModule` quote for the swap direction, or `baseFee` if no module is set. Module calls fail closed: a failed or malformed quote blocks initialization or reverts the affected swap. Preflight does not guarantee future quotes or economic behavior.

`TokenLaunched` records the pool key, initial price, and executed PositionManager plan. `TokensSwept` records tokens sent to the sweep recipient.

The LBP strategies below create a Continuous Clearing Auction and later migrate liquidity to v4. `LBPStrategy.migrate()` is a one-shot action: if migration succeeds, liquidity is deployed to v4; if it reverts, the strategy sweeps the held LP token reserves and raised currency to the initializer's configured `recipient`.

#### FullRangeLBPStrategy
A simple implementation that migrates raised funds to Uniswap V4 as a single full-range position. It is the simplest strategy and is suitable for most use cases.

#### AdvancedLBPStrategy
A more advanced strategy that uses any excess tokens or currency after the full-range position is created to seed one-sided positions.

#### GovernedLBPStrategy
A strategy that lets a trusted entity restrict swapping on the liquidity pool.

#### VirtualLBPStrategy
A strategy that implements a virtual token backed by an underlying token. This is useful for tokens with complex vesting or lockup schedules.

The LBP strategies are provided as-is. Custom auction strategies can extend `LBPStrategyBase`.

### Warnings

Users should be aware that it is trivially easy to create a LBPStrategy and corresponding Auction with malicious parameters. This can lead to a loss of funds or a degraded experience. You must validate all parameters set on each contract in the system before interacting with them.

Since LBPStrategies cannot control the final price of the Auction, or how much currency is raised, it is possible to configure an Auction such that it is impossible to migrate the liquidity to V4. Users should be aware that malicious deployers can design such parameters so a failed migration returns the raised currency and reserved LP tokens to the configured `recipient` instead of creating the expected V4 liquidity.

We strongly recommend that a token with value such as ETH or USDC is used as the `currency`.

### Periphery contracts
The following periphery contracts are provided as examples.

#### TimelockedPositionRecipient
The `TimelockedPositionRecipient` contract is a utility contract for holding a v4 LP position until a timelock period has passed. It is used to ensure that the position is not transferred to the recipient before the timelock expires.

A deployed instance can be used as a `PositionDefinition.recipient` when using an LBPStrategy.

#### FeeSplitter
The `FeeSplitter` is a singleton custodian of native-ETH v4 LP positions with immutable, deploy-time fee splits. `collectFees(uint256[] tokenIds)` permissionlessly collects each position's accrued fees and pushes independent basis-point splits of the native ETH side (`currency0`) and the token side (`currency1`) to fixed recipients. The splitter is itself an ERC721: positions safe-transferred through the PositionManager may carry an abi-encoded beneficiary as transfer data, which mints the splitter's beneficiary NFT (same tokenId as the position) to that address. A fee-beneficiary sentinel recipient resolves per position to the NFT's current holder, so the fee stream is freely transferable with standard ERC721 tooling. Unregistered positions and failed native sends route that share to an immutable per-side fallback, so a collect can never be blocked. `DirectLaunchStrategy` requires an abi-encoded `DirectLaunchConfig` naming the fee beneficiary in `configData` — freely chosen by the launch configuration and carrying no claim of authorship — rejecting only the zero address and the launcher (fees held by the launcher would be sweepable by anyone via `distributeToken`). Positions held by the splitter are irrecoverable by design — there is no owner, operator, or exit path.

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
