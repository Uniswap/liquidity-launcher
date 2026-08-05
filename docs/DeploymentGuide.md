# Deployment Guide

## Table of Contents
- [Deployment Process](#deployment-process)
- [Deployment Requirements](#deployment-requirements)
- [Creating a new token](#creating-a-new-token)
- [Token distribution](#token-distribution)
- [Example](#example)
- [Contract verification](#contract-verification)
- [Legacy deployments (deprecated)](#legacy-deployments-deprecated)

## Deployment Process
Most deployments will be initiated through the `LiquidityLauncher` contract. If you are also creating a new token, see [Creating a new token](#creating-a-new-token).

## Deployment Requirements

This protocol requires deployment on networks that support the Cancun upgrade, specifically:
- **EIP-1153 (Transient Storage)**: Used by `ReentrancyGuardTransient` for gas-efficient temporary storage

Supported networks include Ethereum mainnet (post-Cancun) and L2s that have implemented the Cancun upgrade. Before deploying on a new network, verify that transient storage opcodes (`TLOAD`/`TSTORE`) are supported.

## Creating a new token
You can create a new token by calling the `createToken` function on the `LiquidityLauncher` contract. This will deploy a new token through a specified factory contract. The launcher supports different token standards including ERC20 tokens (UERC20) and Superchain tokens (USUPERC20).

```solidity
function createToken(
    address factory,
    string calldata name,
    string calldata symbol,
    uint8 decimals,
    uint128 initialSupply,
    address recipient,
    bytes calldata tokenData
) external returns (address tokenAddress);
```

If you intend to distribute the token via a strategy in the same transaction, set `recipient` to the `LiquidityLauncher` contract address and batch with `distributeToken` inside `multicall` (see [Token distribution](#token-distribution)). For all other cases — including just minting a token to a user without distributing — set `recipient` to an address you control.

> ⚠️ Tokens held in `LiquidityLauncher` are unprotected: any caller can subsequently invoke `distributeToken` on them with arbitrary strategy parameters. **Only** pass `address(launcher)` as the recipient when the very next call in the same `multicall` is `distributeToken`.

## Token distribution

The launcher uses a **pull** flow: the strategy pulls tokens out of the launcher via `safeTransferFrom` inside its own `initializeDistribution`. The launcher must already hold the tokens before `distributeToken` is invoked. There are two supported ways to get tokens into the launcher, both designed to be batched with `distributeToken` inside `multicall`:

1. **Fresh-mint flow** — call `createToken(recipient=address(launcher), ...)` to mint into the launcher.
2. **Existing-token flow** — call `depositToken(token, amount)` to pull an existing ERC20 balance from `msg.sender` into the launcher via Permit2.

```solidity
struct Distribution {
    address strategy;
    uint128 amount;
    bytes configData;
}

function depositToken(address token, uint160 amount) external;

function distributeToken(
    address token,
    Distribution calldata distribution,
    bytes32 salt
) external;
```

`depositToken` requires the caller to have set up a Permit2 allowance for the launcher (either via a prior `permit2.approve(...)` or by calling `permit(...)` earlier in the same `multicall`). The amount type is `uint160` to match Permit2's allowance type.

The `salt` parameter is forwarded to the selected strategy after being domain-separated by the caller. Strategies and downstream factories that perform deterministic deployments MUST include the provided salt in their address calculation and any matching address prediction helpers.

Depending on the complexity of the strategy, you may need to pass additional parameters to it. These are passed in the `configData` parameter.

`Distribution.strategy` is the contract that receives the launcher's temporary allowance and must pull the full `amount` from the launcher inside `initializeDistribution`. Strategies may create any number of additional contracts, but those contracts are not returned to the launcher; strategy-specific events or prediction helpers should be used when callers need downstream contract addresses.

Strategies that spend native ETH instead of a distributed token (implementing `INativeStrategy`) are run with `distributeWithNative(strategy, configData, salt, nativeAmount)`, which forwards the native amount with the call; no token leg or approval is involved.

> ⚠️ **Always batch token acquisition (`createToken` or `depositToken`) and `distributeToken` inside the same `multicall`.** Tokens that sit in the launcher between transactions can be distributed by anyone with arbitrary strategy parameters.

### LBP hook requirement

When configuring an LBP distribution, the `MigratorParameters.poolParameters.hook` field is the Uniswap v4 hook for the post-auction pool. Any nonzero hook used in this `hook` field MUST inherit `InitializerHook`. The strategy enforces this by checking ERC165 support for `IInitializerHook` during `initializeDistribution`. This is required because `InitializerHook` implements the `beforeInitialize` gate that only allows the singleton `LBPStrategy` to initialize the committed pool.

Do not configure third-party or custom hooks in `hook` unless they inherit `InitializerHook` and are deployed at an address with the correct v4 hook permission bits, including `BEFORE_INITIALIZE`.

Dynamic-fee launches must provide a nonzero hook with the fee logic.

#### Static-fee launches with `hook = address(0)`: hookless pool with strategy-hooked fallback

For static-fee launches with `hook = address(0)`, the migration destination is **state-dependent and chosen at migration time**. `hook = address(0)` does not guarantee the final pool is hookless — it means "prefer the hookless pool, but fall back to the strategy-hooked pool if the hookless pool already exists." A launch configured this way migrates into exactly one of:

- `(currency0, currency1, fee, tickSpacing, address(0))` — the canonical hookless pool, when that pool is still uninitialized at migration time; or
- `(currency0, currency1, fee, tickSpacing, address(strategy))` — the strategy-hooked fallback pool, when the hookless pool has already been initialized.

This fallback is intentional and an accepted operating mode. Hookless pools are preferred because they are simpler and easier to route through, so the strategy targets the canonical hookless pool whenever it is available. The strategy-hooked pool only exists to preserve a migration path when the hookless key has already been consumed; it relies on `LBPStrategy` itself being deployed at a valid `BEFORE_INITIALIZE` hook address (deployment scripts and tests must mine the strategy address accordingly) and self-gating `beforeInitialize`, so no separate `InitializerHook` deployment is required. Integrators routing to a hookless launch's pool should resolve the actual pool key from the `Migrated` event rather than assuming `address(0)`.

### LBPStrategy fund recovery

`migrate()` attempts pool initialization and liquidity creation through an internal self-call. There is no separate recovery step to configure. Launch creators, recipients, and integrators should understand the recovery path:

- **If the internal migration attempt fails, `migrate()` enters recovery** in the same call's failure branch and emits `MigrationFailed`.
- **Recovery returns funds to the configured `recipient`**: it sweeps any raised currency from the initializer and transfers that currency plus the reserved LP tokens (`reservedTokenAmountForLP`) to `recipient`, then emits `FundsRecovered`.
- **The initializer's pool-id reservation is consumed** at the top of `migrate()`, before the attempt, so the same initializer **cannot be retried** through `LBPStrategy.migrate()` afterward — on success or failure.
- **Post-recovery liquidity is manual.** Recovery only returns the assets; it does not create a v4 position. Any desired liquidity must be created manually by the token creator, recipient, or another operator outside the strategy migration flow, subject to the selected pool and hook permissions.

## Example

### Fresh-mint flow (mint + distribute atomically)

The token is minted directly into the launcher and immediately distributed in a single `multicall`.

```solidity
address liquidityLauncher = vm.envAddress("LIQUIDITY_LAUNCHER");
address uerc20Factory = vm.envAddress("UERC20_FACTORY");
address strategy = vm.envAddress("STRATEGY");
uint128 initialSupply = 1000000000000000000000000;

bytes32 graffiti = LiquidityLauncher(liquidityLauncher).getGraffiti(msg.sender);
address precomputedToken = UERC20Factory(uerc20Factory).getUERC20Address(
    "Test Token", "TEST", 18, liquidityLauncher, graffiti
);

Distribution memory distribution = Distribution({
    strategy: strategy,
    amount: initialSupply,
    configData: "" // Add any strategy-specific parameters here
});

bytes[] memory calls = new bytes[](2);
calls[0] = abi.encodeWithSelector(
    LiquidityLauncher.createToken.selector,
    uerc20Factory,
    "Test Token",
    "TEST",
    18,
    initialSupply,
    liquidityLauncher, // mint INTO the launcher so distributeToken can pull
    bytes("")
);
calls[1] = abi.encodeWithSelector(
    LiquidityLauncher.distributeToken.selector, precomputedToken, distribution, bytes32(0)
);

LiquidityLauncher(liquidityLauncher).multicall(calls);
```

### Existing-token flow (deposit + distribute atomically)

For tokens the user already holds, the launcher pulls via Permit2 inside the same `multicall`. The user signs a Permit2 PermitSingle off-chain; the `permit` forwarding call sets up the allowance, `depositToken` pulls the tokens into the launcher, and `distributeToken` hands them off to the strategy — all atomically.

```solidity
// alice already approved permit2 on the token once: token.approve(permit2, type(uint256).max);
// alice signs a permit2 PermitSingle off-chain naming the launcher as spender.

bytes[] memory calls = new bytes[](3);
calls[0] = abi.encodeWithSelector(Permit2Forwarder.permit.selector, alice, permit, sig);
calls[1] = abi.encodeWithSelector(
    LiquidityLauncher.depositToken.selector, token, uint160(amount)
);
calls[2] = abi.encodeWithSelector(
    LiquidityLauncher.distributeToken.selector, token, distribution, bytes32(0)
);

vm.prank(alice);
LiquidityLauncher(liquidityLauncher).multicall(calls);
```

If the user already has an active Permit2 allowance for the launcher, the `permit` call can be omitted.

### Contract verification
Because multiple contracts may be created as part of the initial call to `LiquidityLauncher.distributeToken`, you may need to manually verify the contracts after the deployment with `forge verify-contract`.

## Deployments
The canonical deployments for each contract are in the [Deployment Addresses](../README.md#deployment-addresses) section of the README.

## Legacy deployments (deprecated)

> **Deprecated.** The per-variant LBP strategy factories below were removed in v3.0.0 and consolidated into a single `LBPStrategy` (see the [v3.0.0 changelog](../CHANGELOG.md)). These addresses point to v2.0.0 contracts that are no longer part of the current codebase and are retained for historical reference only. Do not integrate against them for new launches.

### LiquidityLauncher (v1.0.0, deprecated)
LiquidityLauncher was deployed with the initial v1.0.0 launch and is deployed to the same address on all chains. The v1.0.0 version below is only compatible with v1.0.0 and v2.0.0 deployments of other contracts.

| Version | Chain | Address | Commit Hash |
|---------|-------|---------|------------|
| v1.0.0 | Mainnet | 0x00000008412db3394C91A5CbD01635c6d140637C | fd5be9b7a918ca3d925d985dff9bcde82b3b8a9d |

### FullRangeLBPStrategyFactory (v2.0.0, deprecated)

| Version | Chain | Address | Commit Hash |
|---------|-------|---------|------------|
| v2.0.0 | Mainnet | 0x65aF3B62EE79763c704f04238080fBADD005B332 | 610603eed7c35ff504e23ec87cd18ec3f701e746 |
| v2.0.0 | Unichain | 0xAa56d4d68646B4858A5A3a99058169D0100b38e2 | 610603eed7c35ff504e23ec87cd18ec3f701e746 |
| v2.0.0 | Base | 0x39E5eB34dD2c8082Ee1e556351ae660F33B04252 | 610603eed7c35ff504e23ec87cd18ec3f701e746 |
| v2.0.0 | Sepolia | 0x89Dd5691e53Ea95d19ED2AbdEdCf4cBbE50da1ff | 610603eed7c35ff504e23ec87cd18ec3f701e746 |
| v2.0.0 | Base Sepolia | 0xa3A236647c80BCD69CAD561ACf863c29981b6fbC | 610603eed7c35ff504e23ec87cd18ec3f701e746 |

### AdvancedLBPStrategyFactory (v2.0.0, deprecated)

| Version | Chain | Address | Commit Hash |
|---------|-------|---------|------------|
| v2.0.0 | Mainnet | 0x982DC187cbeB4E21431C735B01Ecbd8A606129C5 | 610603eed7c35ff504e23ec87cd18ec3f701e746 |
| v2.0.0 | Unichain | 0xeB44195e1847F23D4ff411B7d501b726C7620529 | 610603eed7c35ff504e23ec87cd18ec3f701e746 |
| v2.0.0 | Base | 0x9C5A6fb9B0D9A60e665d93a3e6923bDe428c389a | 610603eed7c35ff504e23ec87cd18ec3f701e746 |
| v2.0.0 | Sepolia | 0xdC3553B7Cea1ad3DAB35cBE9d40728C4198BCBb6 | 610603eed7c35ff504e23ec87cd18ec3f701e746 |
| v2.0.0 | Base Sepolia | 0x67E24586231D4329AfDbF1F4Ac09E081cFD1e6a6 | 610603eed7c35ff504e23ec87cd18ec3f701e746 |

### GovernedLBPStrategyFactory (v2.0.0, deprecated)

| Version | Chain | Address | Commit Hash |
|---------|-------|---------|------------|
| v2.0.0 | Base | 0xBc869216dAD02E1A95c1478a459D064b16F41B24 | 610603eed7c35ff504e23ec87cd18ec3f701e746 |
| v2.0.0 | Base Sepolia | 0xB460228ACa3bbf8FaDB781d22Cf051f55e7460A9 | 610603eed7c35ff504e23ec87cd18ec3f701e746 |
