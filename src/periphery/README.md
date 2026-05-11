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

A single contract, owned by governance, that tells an integrator exactly **how much** protocol fee to take on a given currency amount and **who** to send it to. Fee rates use **pips** (1 pip = 0.0001%, denominator 1,000,000), matching v4's `ProtocolFeeLibrary`.

### The question an integrator asks

```solidity
// Source of truth for fee deduction
(uint256 feeAmount, address recipient) = controller.getProtocolFeeAmount(currency, amount);
```

### How the fee is determined

The controller resolves the fee in two steps:

1. **Is there a per-currency schedule?** If yes, use it.
2. **Otherwise, use the global flat fee.**

Both branches always return the **global recipient**. Per-currency configs only override the *rate schedule*, not the recipient.

### Global fee (off by default)

The protocol fee is **off by default** — a freshly deployed controller returns 0 fee and `address(0)` recipient, similar to v4's protocol fee design. Governance can turn it on at any time via `setGlobalProtocolFeeSettings`:

```solidity
controller.setGlobalProtocolFeeSettings(50_000, treasury); // 5% on all currencies
```

To turn the protocol fee fully off — across the global flat fee **and** every per-currency override — clear the global recipient:

```solidity
controller.setGlobalProtocolFeeSettings(0, address(0));
```

While the global recipient is `address(0)`, `getProtocolFeeAmount` returns `(0, address(0))` for every currency regardless of any per-currency schedule still in storage.

### Per-currency override (optional)

For currencies that warrant a non-flat schedule, governance can install up to `MAX_FEES` (3) progressive tiers. Progressive means each tier's pips rate only applies to the portion of the amount *within that tier's range* — the same pattern as income tax brackets. No cliff effects, no gaming around thresholds.

A tier is `{ lowerThreshold, protocolFeePips }` where `lowerThreshold` is the **lower bound** of the bracket (in currency base units) and `protocolFeePips` is the fee rate in pips. The **first tier's lowerThreshold must be 0** and subsequent thresholds must be strictly ascending. The **last tier's rate** applies to all remaining currency above its lowerThreshold. This matches the bracket pattern used in `MigratorParams.LiquidityAllocationBracket`.

To cap fees (stop charging beyond a certain amount), add a final tier with `protocolFeePips: 0`.

### Worked example

A three-tier schedule on ETH (last tier extends to infinity):

```
Tier 1: [0, 10 ETH)   → 2%    (20,000 pips)
Tier 2: [10, 50 ETH)  → 1%    (10,000 pips)
Tier 3: [50 ETH, ∞)   → 0.5%  (5,000 pips)
```

Configured via:

```solidity
IProtocolFeeController.Fee[] memory tiers = new IProtocolFeeController.Fee[](3);
tiers[0] = IProtocolFeeController.Fee({ lowerThreshold: 0,     protocolFeePips: 20_000 });
tiers[1] = IProtocolFeeController.Fee({ lowerThreshold: 10e18, protocolFeePips: 10_000 });
tiers[2] = IProtocolFeeController.Fee({ lowerThreshold: 50e18, protocolFeePips: 5_000  }); // last tier extends to infinity
controller.setProtocolFeePerCurrency(eth, tiers);
```

Fees on an 80 ETH raise:

```
(10 ETH × 2%) + (40 ETH × 1%) + (30 ETH × 0.5%) = 0.75 ETH  (0.9375% effective)
```

To cap fees beyond a certain amount, spend the final tier slot on a 0-pips tail. Reducing the schedule to two real tiers + cap, so it still fits within `MAX_FEES`:

```solidity
IProtocolFeeController.Fee[] memory tiers = new IProtocolFeeController.Fee[](3);
tiers[0] = IProtocolFeeController.Fee({ lowerThreshold: 0,      protocolFeePips: 20_000 });
tiers[1] = IProtocolFeeController.Fee({ lowerThreshold: 10e18,  protocolFeePips: 10_000 });
tiers[2] = IProtocolFeeController.Fee({ lowerThreshold: 100e18, protocolFeePips: 0      }); // cap, no fee beyond 100 ETH
controller.setProtocolFeePerCurrency(eth, tiers);
```

### Constraints at a glance

| Parameter | Limit | Reason |
| --- | --- | --- |
| Tiers per currency | 3 (`MAX_FEES`) | Reverts with `InvalidFeeLength` above this. |
| `lowerThreshold` | `uint128` | Lower bound of the bracket in currency base units. |
| `protocolFeePips` | 0–1,000,000 | 100% max (`PIPS_DENOMINATOR`). |
| First tier `lowerThreshold` | must be 0 | Schedule must start at 0. |
| Subsequent `lowerThreshold`s | strictly ascending | Non-overlapping brackets. |
| Last tier | extends to infinity | Its rate applies to all amount above its `lowerThreshold`. |

### Clearing a per-currency override

Call `setProtocolFeePerCurrency(currency, new Fee[](0))` to revert a currency back to the global fee.

### Deployment expectation

`ProtocolFeeController` uses solady's `Ownable` and takes the initial owner as a constructor arg:

```solidity
new ProtocolFeeController(governance);
```

The protocol fee is off by default. The expected post-deploy sequence is:

1. Optionally call `setGlobalProtocolFeeSettings(pips, recipient)` to turn on the global fee.
2. If the deployer was set as the initial owner, transfer ownership to the governance multisig/timelock.

The fee can be enabled or updated at any time after deployment.

### Notes for integrators

- **Always forward fees to the returned `recipient`.** The recipient is the *global* recipient; per-currency configs do not override it.
- **`amount > type(uint256).max / 1_000_000` is silently clamped inside the controller** to prevent overflow in internal multiplications. This threshold is ~`1.16 × 10^71`, far beyond any realistic raise, but something to be aware of if you're feeding in adversarial inputs.
- **Events.** `GlobalProtocolFeeSettingsUpdated` and `ProtocolFeePerCurrencyUpdated` let off-chain indexers reconstruct the current schedule. `getCurrencyFees(currency)` returns the full tier array for a given currency.
