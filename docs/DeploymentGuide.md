# Deployment Guide

## Table of Contents
- [Deployment Process](#deployment-process)
- [Deployment Requirements](#deployment-requirements)
- [Creating a new token](#creating-a-new-token)
- [Token distribution](#token-distribution)
- [Example](#example)
- [Contract verification](#contract-verification)

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
    uint256 amount;
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

> ⚠️ **Always batch token acquisition (`createToken` or `depositToken`) and `distributeToken` inside the same `multicall`.** Tokens that sit in the launcher between transactions can be distributed by anyone with arbitrary strategy parameters.

### LBP hook requirement

When configuring an LBP distribution, the `MigratorParameters.poolParameters.hook` field is the Uniswap v4 hook for the post-auction pool. Any nonzero hook used in this `hook` field MUST inherit `InitializerHook`. The strategy enforces this by checking ERC165 support for `IInitializerHook` during `initializeDistribution`. This is required because `InitializerHook` implements the `beforeInitialize` gate that only allows the singleton `LBPStrategy` to initialize the committed pool.

Do not configure third-party or custom hooks in `hook` unless they inherit `InitializerHook` and are deployed at an address with the correct v4 hook permission bits, including `BEFORE_INITIALIZE`.

Passing `address(0)` keeps a static-fee launch on the hookless pool when that pool has not been initialized. If the hookless pool already exists at migration time, `LBPStrategy` uses its own address as the v4 hook and initializes the strategy-hooked pool. This fallback relies on `LBPStrategy` itself being deployed at a valid `BEFORE_INITIALIZE` hook address; deployment scripts and tests must mine the strategy address accordingly. Dynamic-fee launches must provide a nonzero hook with the fee logic.

### LBPStrategy `recoveryDelayBlocks`

`LBPStrategy`'s constructor accepts an immutable `recoveryDelayBlocks` parameter for forward compatibility, but the current implementation no longer uses it: recovery is no longer a separate, delayed entrypoint. Instead, `migrate()` is the sole public entrypoint and internally waterfalls — first attempting the configured-plan migration, then a full-range LP attempt on the strategy-as-hook pool (independent of `MigratorParameters.hook`), and finally a release of held assets to `recipient` if both prior tiers fail. The argument can be set to any value (e.g. `0`) at deploy time without changing behavior.

## Example

### Fresh-mint flow (mint + distribute atomically)

The token is minted directly into the launcher and immediately distributed in a single `multicall`.

```solidity
address liquidityLauncher = vm.envAddress("LIQUIDITY_LAUNCHER");
address uerc20Factory = vm.envAddress("UERC20_FACTORY");
address strategyFactory = vm.envAddress("STRATEGY_FACTORY");
uint128 initialSupply = 1000000000000000000000000;

bytes32 graffiti = LiquidityLauncher(liquidityLauncher).getGraffiti(msg.sender);
address precomputedToken = UERC20Factory(uerc20Factory).getUERC20Address(
    "Test Token", "TEST", 18, liquidityLauncher, graffiti
);

Distribution memory distribution = Distribution({
    strategy: strategyFactory,
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
