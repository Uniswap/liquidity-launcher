# Periphery

Peripheral contracts used alongside LBP strategies.

## Contents

| Contract | Purpose |
| --- | --- |
| [`TimelockedPositionRecipient`](./TimelockedPositionRecipient.sol) | Holds one or more v4 LP positions until a timelock block is reached, then approves a configured operator to transfer them. Base contract for the two recipients below. |
| [`PositionFeesForwarder`](./PositionFeesForwarder.sol) | Adds a permissionless `collectFees(tokenId)` entrypoint that collects LP fees from a held position and forwards both sides to an immutable recipient. |
| [`BuybackAndBurnPositionRecipient`](./BuybackAndBurnPositionRecipient.sol) | Adds a permissionless `collectFees(tokenId, minCurrency)` entrypoint that (a) pulls a minimum amount of `token` from the caller and burns it, (b) collects LP fees, (c) forwards the `token` side to the burn address, (d) forwards the `currency` side to the caller. Designed so MEV searchers can profitably trigger buyback-and-burns. |
| [`ProtocolFeeController`](./ProtocolFeeController.sol) | Governance-controlled source of truth for the protocol fee applied to currency raised by a launch. Integrators call it at fee-settlement time to discover the fee amount and recipient. See below. |
| [`hooks/SelfInitializerHook`](./hooks/SelfInitializerHook.sol) | Abstract v4 hook that restricts `initializePool` to the hook contract itself. Used by strategies that must deterministically control the initial pool state. |

## ProtocolFeeController

A single contract, owned by governance, that tells an integrator exactly **how much** protocol fee to take on a given currency amount and **who** to send it to.

### The two questions an integrator asks

```solidity
// Primary API — source of truth for fee deduction
(uint256 feeAmount, address recipient) = controller.getProtocolFeeAmount(currency, amount);

// Display-only API — truncated effective rate for UIs
(uint24 bps, address recipient) = controller.getProtocolFeeBps(currency, amount);
```

`getProtocolFeeAmount` is what you use on-chain. `getProtocolFeeBps` is what you show in a UI — it's `feeAmount * 10_000 / amount` truncated to a `uint24`, so it can be off by up to 1 bps from the exact fee.

### How the fee is determined

The controller resolves the fee in two steps:

1. **Is there a per-currency schedule?** If yes, use it.
2. **Otherwise, use the global flat fee.**

Both branches always return the **global recipient**. Per-currency configs only override the *rate schedule*, not the recipient.

### Global fee (the default)

A single `(bps, recipient)` pair applied uniformly to every currency that doesn't have an override. This is set once by governance via `setGlobalProtocolFeeSettings` and covers the common case.

```solidity
controller.setGlobalProtocolFeeSettings(500, treasury); // 5% on all currencies
```

### Per-currency override (optional)

For currencies that warrant a non-flat schedule (e.g. a more-valuable currency where a flat rate becomes abusive at scale), governance can install up to **3 progressive tiers** and an optional **amount cap**. Progressive means each tier's bps rate only applies to the portion of the amount *within that tier's range* — the same pattern as income tax brackets. No cliff effects, no gaming around thresholds.

A tier is `{ startAmount, protocolFeeBps }`. `startAmount` (and `cap`) are expressed in *scaled units* where `1 unit = 10^scale` base units of the currency. A single `scale` applies to all tiers for a given currency. Pick a scale that makes your tier boundaries human-readable:

| Currency | decimals | typical scale | 1 unit = | uint16 max = |
| --- | --- | --- | --- | --- |
| ETH  | 18 | 18 | 1 ETH   | 65,535 ETH |
| ETH  | 18 | 16 | 0.01 ETH | 655.35 ETH |
| USDC | 6  | 6  | 1 USDC  | 65,535 USDC |
| UNI  | 18 | 22 | 10,000 UNI | 655,350,000 UNI |

`cap` is the amount (in scaled units) beyond which no further fees accrue — the fee plateaus. Set `cap = 0` for no cap. `cap` must be strictly greater than the last tier's `startAmount`.

### Worked example

A three-tier schedule on ETH (`scale = 18`, so `1 unit = 1 ETH`), capped at 100 ETH:

```
Tier 1: [0, 10)   ETH  → 2.00%
Tier 2: [10, 50)  ETH  → 1.00%
Tier 3: [50, 100] ETH  → 0.50%
Cap:    100 ETH
```

Configured via:

```solidity
IProtocolFeeController.Fee[] memory tiers = new IProtocolFeeController.Fee[](3);
tiers[0] = IProtocolFeeController.Fee({ startAmount: 0,  protocolFeeBps: 200 });
tiers[1] = IProtocolFeeController.Fee({ startAmount: 10, protocolFeeBps: 100 });
tiers[2] = IProtocolFeeController.Fee({ startAmount: 50, protocolFeeBps: 50  });
controller.setProtocolFeePerCurrency(eth, 18, tiers, 100);
```

Fees on an 80 ETH raise:

```
(10 ETH × 2.00%) + (40 ETH × 1.00%) + (30 ETH × 0.50%) = 0.75 ETH  (0.9375% effective)
```

Fees on a 150 ETH raise (above the cap):

```
(10 ETH × 2.00%) + (40 ETH × 1.00%) + (50 ETH × 0.50%) = 0.85 ETH  (0.567% effective)
```

Once past the cap, the raw fee stays at 0.85 ETH regardless of how much more is raised.

### Constraints at a glance

| Parameter | Limit | Reason |
| --- | --- | --- |
| Tiers per currency | 0–3 | Slot packing. |
| `scale` | 0–68 | Bounds `bracketAmount × bps` below `type(uint256).max`. |
| `startAmount`, `cap` | 0–65,535 (scaled) | Packed as `uint16`. |
| `protocolFeeBps` | 0–10,000 | 100% max. |
| `fees[0].startAmount` | must be 0 | First tier is the base rate. |
| Tier `startAmount`s | strictly ascending | Non-overlapping brackets. |
| `cap` | 0, or strictly greater than the last tier's `startAmount` | Zero means no cap; equality would be a zero-width bracket. |

### Clearing a per-currency override

Call `setProtocolFeePerCurrency(currency, 0, new Fee[](0), 0)` to revert a currency back to the global fee. The per-currency slot is zeroed.

### Deployment expectation

`ProtocolFeeController` is `Owned` by `msg.sender` at deployment and **does not** take constructor args. The expected post-deploy sequence, ideally atomic, is:

1. Call `setGlobalProtocolFeeSettings(bps, recipient)` to set the initial global fee.
2. Transfer ownership to the governance multisig/timelock.

Until step 1 is done, `getProtocolFeeAmount` and `getProtocolFeeBps` return a zero-address recipient. Integrators should treat an unset controller as misconfigured.

### Notes for integrators

- **Use `getProtocolFeeAmount`, not `getProtocolFeeBps`, for on-chain accounting.** The bps value is truncated.
- **Always forward fees to the returned `recipient`.** The recipient is the *global* recipient; per-currency configs do not override it.
- **`amount > type(uint256).max / 10_000` is silently clamped inside the controller** to prevent overflow in internal multiplications. This threshold is ~`1.16 × 10^73`, far beyond any realistic raise, but something to be aware of if you're feeding in adversarial inputs.
- **Events.** `GlobalProtocolFeeSettingsUpdated` and `ProtocolFeePerCurrencyUpdated` let off-chain indexers reconstruct the current schedule; the contract does not expose a decoded view of the per-currency config.
