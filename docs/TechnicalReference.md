# Technical Reference

## Table of Contents
- [Core Components](#core-components)
    - [LiquidityLauncher](#liquiditylauncher)
    - [Token Factories](#token-factories)
    - [Distribution Strategies](#distribution-strategies)
        - [InstantLaunchStrategy](#instantlaunchstrategy)
        - [LBPStrategy](#lbpstrategy)
        - [UniversalRouterStrategy](#universalrouterstrategy)
        - [TokenSplitter](#tokensplitter)
        - [MerkleClaimFactory](#merkleclaimfactory)
    - [Warnings](#warnings)
    - [Periphery contracts](#periphery-contracts)
- [Contract Interactions](#contract-interactions)
    - [Typical Launch Flow](#typical-launch-flow)
    - [LBP Hook Requirement](#lbp-hook-requirement)
- [Key Interfaces](#key-interfaces)
- [Important Safety Notes](#important-safety-notes)

## Core Components

### LiquidityLauncher

The main entry point. It exposes four functions, designed to be batched with `multicall`:

`createToken` deploys a new token through a caller-specified `ITokenFactory`. The launcher forwards name, symbol, decimals, supply, recipient, and factory-specific `tokenData`, plus a graffiti value derived from the caller (`keccak256(abi.encode(msg.sender))`) that factories can embed in the token. The factory address is not validated — callers choose which factory to trust.

`depositToken` pulls an existing ERC20 balance from `msg.sender` into the launcher via Permit2. Used for the "distribute a token I already hold" flow; the caller must have a Permit2 allowance for the launcher (set in a prior tx or via `permit(...)` earlier in the same multicall).

`distributeToken` hands off tokens already held by the launcher to a strategy. The launcher force-approves the strategy for `distribution.amount` and the strategy pulls via `safeTransferFrom` inside its own `initializeDistribution`; the call reverts with `AllowanceNotFullyConsumed` if any allowance remains. Token acquisition (`createToken` or `depositToken`) and `distributeToken` MUST be batched in the same `multicall`; tokens left in the launcher between transactions can be distributed by any caller.

`distributeWithNative` runs an `INativeStrategy` with forwarded native ETH instead of a distributed token. Nothing is approved; the strategy spends the forwarded value.

### Token Factories

Token factories are external to this repository. The launcher calls any address implementing `ITokenFactory` (from [uerc20-factory](https://github.com/Uniswap/uerc20-factory)). The canonical factories are:

- **UERC20Factory** — standard ERC20 tokens with extended metadata, Permit2 support, and an immutable `graffiti()` recording the original creator. CREATE2 addresses derived from token parameters.
- **USUPERC20Factory** — adds Superchain support: the same address on multiple chains, with only the home chain holding the initial supply.

### Distribution Strategies

The distribution system is modular: any contract implementing `IStrategy` (or `INativeStrategy` for native-funded runs) can receive a distribution from the launcher.

#### InstantLaunchStrategy

`InstantLaunchStrategy` launches a fixed-supply token directly into a hookless, native-ETH-paired v4 pool in one call. There is no auction or graduation step, and nothing about the pool is caller-configurable — the launch shape is fixed at deployment:

- Supply MUST be exactly 1,000,000,000 tokens with 18 decimals (`TOTAL_SUPPLY = 1e9 * 1e18`), and the token's reported `totalSupply()` must match.
- The pool is `(native ETH, token)` with a 25 bps LP fee, tick spacing 60, and no hook. Initialization reverts if that pool key already exists.
- The opening tick and the resulting position liquidity are immutables set at deployment.

The full supply is placed as a single-sided position spanning `[MIN_LAUNCH_TICK, initialTick]` — entirely on the token side of the opening price. `MIN_LAUNCH_TICK` is chosen so that overflowing v4's per-tick max liquidity would require more than the total supply. Rounding dust left after minting is burned to `0xdead`.

`configData` MUST be a non-empty abi-encoded `InstantLaunchConfig` naming a `feeBeneficiary` (not zero, not the launcher), even when creator fees are disabled. If a `BeneficiaryVault` is configured, the strategy registers the beneficiary before parting with the position; a vault of `address(0)` opts out of creator fees for all launches.

The LP NFT is transferred to the singleton [`FeeSplitter`](../src/periphery/README.md), which locks it permanently and permissionlessly splits its fees between the configured recipients (including the beneficiary's share via the vault).

Fee-on-transfer and rebasing tokens are not supported: the strategy requires the pulled amount to arrive exactly.

`TokenLaunched` records the pool id, token, final position recipient (the fee splitter), and pool key.

#### LBPStrategy

`LBPStrategy` runs an auction-based launch: it deploys an auction contract (the *initializer*) through an external `IDistributorFactory` fixed at construction, and later migrates the raised funds plus reserved tokens into a v4 pool at the auction's clearing price.

`initializeDistribution` decodes `configData` as `(MigratorParameters, bytes initializerParams)`, validates the parameters, deploys the initializer, and splits the pulled supply: `totalSupply - reservedTokenAmountForLP` goes to the initializer for the auction, `reservedTokenAmountForLP` stays in the strategy until migration. The target pool id is reserved at registration so no other initializer can claim the same pool key.

Key `MigratorParameters` fields:

- `migrationBlock` — earliest block `migrate()` can run; must be after the initializer's `endBlock`.
- `reservedTokenAmountForLP` — token-side LP budget held by the strategy.
- `recipient` — receives unused currency and tokens after migration, and the recovered funds if migration fails.
- `positionRecipient` — default recipient of minted LP NFTs; individual `PositionDefinition`s may set an `overridePositionRecipient`.
- `positionDefinitions` — abi-encoded `PositionDefinition[]` describing the weighted LP plan (see `PositionPlanner`).
- `lpAllocationSchedule` — abi-encoded `LiquidityAllocationBracket[]` mapping currency raised to the share allocated to LP, bracket by bracket.
- `poolParameters` — fee, tick spacing, and hook for the migrated pool. See [LBP Hook Requirement](#lbp-hook-requirement).

Migration mechanics are covered in [Contract Interactions](#contract-interactions).

#### UniversalRouterStrategy

`UniversalRouterStrategy` runs a caller-supplied Universal Router route, so a launch and a buy fit in one launcher `multicall`. `configData` is an abi-encoded `UniversalRouterConfig`: the router to use (so one deployment serves every router version), a recipient for any distributed token the route did not spend, and the route itself (`abi.encode(bytes commands, bytes[] inputs, uint256 deadline)`).

Both entry points are launcher-only. `initializeDistribution` pays the distributed token to the router and executes the route; `initializeWithNative` executes the route with the forwarded native ETH. The strategy holds no balance between calls and has no `receive`, so routes MUST sweep their own outputs: use `TAKE` with an explicit recipient, never `TAKE_ALL` (which pays the strategy, where output is claimable by anyone), and route unspent native to the route's own recipient.

#### TokenSplitter

`TokenSplitter` splits a distribution across N recipients with no custody: tokens move directly from the launcher to each recipient via `safeTransferFrom`. `configData` is an abi-encoded `Split[]` of `(recipient, amount)` pairs whose amounts MUST sum to exactly `totalSupply`.

#### MerkleClaimFactory

`MerkleClaimFactory` deploys a `MerkleClaim` — Uniswap's audited `MerkleDistributorWithDeadline`, pinned to Solidity 0.8.17 and deployed from embedded creation code — and funds it with the distribution. `configData` is `abi.encode(bytes32 merkleRoot, address owner, uint256 endTime)`; an `endTime` of 0 disables the deadline. After `endTime`, the (trusted) owner can withdraw unclaimed tokens.

### Warnings

It is trivially easy to create an LBPStrategy distribution and corresponding auction with malicious parameters, which can lead to loss of funds or a degraded experience. Validate all parameters set on each contract in the system before interacting with it.

Since `LBPStrategy` cannot control the final price of the auction or how much currency is raised, it is possible to configure an auction that can never migrate to v4. Malicious deployers can design such parameters so a failed migration returns the raised currency and reserved LP tokens to the configured `recipient` instead of creating the expected v4 liquidity.

We strongly recommend using a token with established value, such as ETH or USDC, as the `currency`.

### Periphery contracts

Periphery contracts are documented in [`src/periphery/README.md`](../src/periphery/README.md). In brief:

- **FeeSplitter** — zero-admin custodian of native-ETH v4 LP positions with immutable, deploy-time fee splits. `collectFees(uint256[] tokenIds)` permissionlessly collects each position and pushes independent basis-point shares of native ETH (`currency0`) and token (`currency1`); native shares are force-sent. Positions sent to it are irrecoverable by design.
- **BeneficiaryVault** — a claim recipient whose transferable ERC721 represents a position's fee beneficiary. `registerBeneficiary(tokenId, beneficiary)` is authorized by position custody, so a depositor registers BEFORE transferring the position to a terminal custodian like the FeeSplitter. Unregistered positions pay out to immutable per-side fallbacks.
- **UERC20BeneficiaryVault** — a `BeneficiaryVault` that also lets the creator of a launcher-created UERC20 claim unregistered positions pairing that token, proven through the token's `graffiti()`. Exists for custodians that predate the vault and never registered a beneficiary (e.g. `LBPStrategy` positions).
- **BuybackAndBurnClaimRecipient** — pays a claim's attributed amounts to an `IClaimExecutor`, which may perform a buyback during the callback; afterwards the recipient pulls a fixed minimum of the position's `currency1` from the executor and sends it to the burn address.
- **CompoundingClaimRecipient** — pays a claim's attributed amounts to an `IClaimExecutor` and requires the position's liquidity to have grown by at least `minLiquidityIncrease` when the callback returns. The executor performs the actual deposit and liquidity increase.
- **TimelockedPositionRecipient** — holds v4 LP positions until a timelock block, after which anyone can approve the configured operator to transfer them.
- **ProtocolFeeController** — governance-owned source of truth for the protocol fee on currency raised by a launch, with a global flat rate and optional per-currency progressive brackets. See the [periphery README](../src/periphery/README.md#protocolfeecontroller) for configuration details.

## Contract Interactions

### Typical Launch Flow

#### 1. Token Creation and Distribution

Use `LiquidityLauncher.multicall` to atomically batch token acquisition with `distributeToken`. Two supported flows:

- **Fresh mint:** `createToken(recipient=address(launcher), ...)` + `distributeToken(...)` — the factory mints directly into the launcher.
- **Existing token:** `permit(...)` (optional, if no active Permit2 allowance) + `depositToken(token, amount)` + `distributeToken(...)` — pulls the caller's tokens into the launcher via Permit2.

Either way, the strategy then pulls the tokens out of the launcher via `safeTransferFrom` inside its own `initializeDistribution`.

For an instant launch, that is the whole lifecycle: the pool, position, and fee custody are final at the end of the `multicall`. The remaining steps apply to LBP launches.

#### 2. Auction Phase

The strategy deploys the initializer and transfers it the auction supply. The auction runs according to the initializer's own parameters.

#### 3. Migration to Uniswap V4

From `migrationBlock` onward, anyone can call `migrate(initializer)` to:

- Verify the initializer is registered for the reserved pool id and consume the reservation (making the initializer one-shot — a second `migrate` call reverts with `InitializerNotRegistered`)
- Sweep the raised currency from the initializer, checking it matches the initializer's reported `currencyRaised`
- Apply the `lpAllocationSchedule` brackets to derive the currency-side LP budget
- Initialize the v4 pool at the auction's clearing price
- Mint liquidity according to the weighted `positionDefinitions`, plus an implicit full-range position from any leftover budget
- Transfer each LP NFT to its `overridePositionRecipient` when set, otherwise to `positionRecipient` (the full-range fallback always goes to `positionRecipient`)
- Sweep unused currency and unused reserved tokens to `recipient`

Unsold auction tokens stay in the initializer and are claimed through the initializer's own `tokensRecipient` path.

The actual pool initialization and liquidity creation run through an internal self-call (`tryMigrate`), so a failure can be caught and handled in the same transaction.

#### 4. Migration Failure and Recovery

If the internal migration attempt reverts, `migrate()` catches the revert and treats the migration as terminal:

- Sweeps any raised currency still held by the initializer to the strategy and forwards it to the configured `recipient`.
- Transfers the held `reservedTokenAmountForLP` to `recipient`.
- Emits `FundsRecovered` and `MigrationFailed`.

The pool-id reservation was already consumed at the top of `migrate()`, so the same initializer cannot be retried. Recovery only returns assets; it creates no v4 position — any desired liquidity must be created manually afterwards. Because each initializer's reservation is consumable exactly once, one initializer's recovery cannot reach another initializer's reserves for the same token.

This prevents funds from being stuck behind a migration path that will never become valid.

**Note:** To optimize gas costs, minimal dust amounts may be foregone and locked in the PoolManager rather than swept at the end of migration.

#### 5. Ways Migration Can Fail

The strategy is written to make migration difficult to grief, but it cannot guarantee that every configured launch can create v4 liquidity. Treat migration safety as part of launch validation, especially when a launcher presents auctions as curated or safe.

`migrate()` can revert before attempting migration if the initializer is not registered, the reservation was already consumed, or the current block is before `migrationBlock`. Failure recovery itself can revert if the token transfer to the configured `recipient` reverts (native currency is force-sent, so an ETH-rejecting recipient cannot block recovery — an ERC20 that blocks the recipient can).

The internal migration attempt can fail (triggering recovery) when, among other causes:

- **Malicious or non-standard token:** the launched token reverts, misbehaves on transfer, or blocks transfers to the PositionManager. Fee-on-transfer and rebasing tokens are unsupported and break accounting assumptions.
- **Malicious hook:** a configured v4 hook can revert during pool initialization or liquidity modification, or make the committed pool unsafe for users. The `InitializerHook` check does not prove the hook's economic behavior is safe.
- **Position definitions that resolve to nothing:** tiny budgets, extreme prices, or ranges that collapse after clamping and snapping can leave no mintable positions, which reverts with `NoPositionsCreated`.
- **Pool or PositionManager state at migration time:** definitions that were valid at initialization can still fail during mint execution at the discovered price.

When recovery succeeds, no v4 LP is created by the strategy; the raised currency and reserved LP tokens are returned to `recipient`.

### LBP Hook Requirement

`MigratorParameters.poolParameters.hook` commits the exact v4 hook for the post-auction pool. Any nonzero hook MUST inherit `InitializerHook`, which enables the `BEFORE_INITIALIZE` permission, supports `IInitializerHook` via ERC165, and rejects pool initialization unless the PoolManager-reported sender is its authorized address. During `initializeDistribution` the strategy verifies the hook's ERC165 support, that its `authorized()` is the strategy, that it is a valid v4 hook address for the configured fee, and that the target pool is not already initialized.

This protects the committed pool from permissionless initialization at an arbitrary price. `GatedSwapHook` inherits `InitializerHook` and satisfies the requirement.

`address(0)` is the only exception, and only for static-fee pools. With `hook == address(0)`, migration first targets the canonical hookless pool; if that pool is already initialized, the strategy switches the key to itself as the hook and initializes the strategy-hooked pool instead. `LBPStrategy` is deployed at a valid `BEFORE_INITIALIZE` hook address and rejects all `beforeInitialize` callbacks (v4 skips the callback when the sender is the hook itself, so self-initialization passes). Dynamic-fee pools must configure a nonzero hook, because the strategy implements no fee logic. See the [Deployment Guide](./DeploymentGuide.md#lbp-hook-requirement) for the integrator-facing details.

## Key Interfaces

**ILiquidityLauncher** — the main launcher interface for creating and distributing tokens.

**IStrategy** — implemented by strategies the launcher hands off to. `initializeDistribution()` is responsible for pulling `totalSupply` of `token` from `msg.sender` (the launcher) via `safeTransferFrom`; the launcher pre-approves the strategy for the full amount before invoking it. The function returns nothing; strategy-specific events or prediction helpers expose any child contracts.

**INativeStrategy** — implemented by strategies funded with forwarded native ETH via `distributeWithNative` instead of a token allowance.

**IDistributor** — implemented by contracts that receive and distribute tokens (e.g. the LBP initializer). Distributors use a push-based token model: the caller sends token funds to the distributor, then MUST call `onTokensReceived()` so the distributor can capture post-funding setup atomically.

**IDistributorFactory** — implemented by factories that parent strategies use to deploy distributors, such as the LBP strategy's initializer factory. Exposes `create(...)` and a sender-aware `getAddress(...)`; it does not fund the distributor, so the calling strategy remains responsible for token movement and `onTokensReceived()`.

**ITokenFactory** — the token-creation interface (from uerc20-factory) that `createToken` calls into.

## Important Safety Notes

⚠️ **Rebasing tokens and fee-on-transfer tokens are NOT compatible with LiquidityLauncher.** The system is designed for standard ERC20 tokens and will not function correctly with tokens that have dynamic balances or transfer fees.

⚠️ **Always batch token acquisition and distribution inside a single `multicall`.** The launcher uses a pull-based hand-off: tokens must already be in the launcher when `distributeToken` is called. If tokens sit in the launcher between transactions — for example, because you `createToken(recipient=launcher)` or `depositToken` in one tx and `distributeToken` in another — **any caller can call `distributeToken` on them with an arbitrary strategy and arbitrary parameters and steal them.** The supported flows are:

- **Fresh mint:** `createToken(recipient=address(launcher), ...) + distributeToken(...)` in one `multicall`.
- **Existing token:** `permit(...) (optional) + depositToken(...) + distributeToken(...)` in one `multicall`.

Anything else is unsafe.
