# Periphery

Peripheral contracts used alongside launch strategies.

## Contents

| Contract | Purpose |
| --- | --- |
| [`TimelockedPositionRecipient`](./TimelockedPositionRecipient.sol) | Holds one or more v4 LP positions until a timelock block is reached, then approves a configured operator to transfer them. Base contract for the two recipients below. |
| [`PositionFeesForwarder`](./PositionFeesForwarder.sol) | Adds a permissionless `collectFees(tokenId)` entrypoint that collects LP fees from a held position and forwards both sides to an immutable recipient. |
| [`BuybackAndBurnPositionRecipient`](./BuybackAndBurnPositionRecipient.sol) | Adds a permissionless `collectFees(tokenId, minCurrency)` entrypoint that (a) pulls a minimum amount of `token` from the caller and burns it, (b) collects LP fees, (c) forwards the `token` side to the burn address, (d) forwards the `currency` side to the caller. Designed so MEV searchers can profitably trigger buyback-and-burns. |
| [`ProtocolFeeController`](./ProtocolFeeController.sol) | Governance-controlled source of truth for the protocol fee applied to currency raised by a launch. Integrators call it at fee-settlement time to discover the fee amount and recipient. See below. |
| [`SelfInitializerMixin`](../strategies/lbp/SelfInitializerMixin.sol) | Abstract mixin for v4 hooks that may only initialize their own pools (restricts `beforeInitialize` to self-calls). Used by strategies that must deterministically control the initial pool state. |

## ProtocolFeeController

A single contract, owned by governance, that tells an integrator exactly **how much** protocol fee to take on a given currency amount and **who** to send it to. Fee rates use **pips** (1 pip = 0.0001%, denominator 1,000,000), matching v4's `ProtocolFeeLibrary`.

### The question an integrator asks

```solidity
// Source of truth for fee deduction
uint256 feeAmount = controller.getProtocolFeeAmount(currency, amount);
```

### How the fee is determined

The controller resolves the fee in two steps:

1. **Is there a per-currency schedule?** If yes, use it.
2. **Otherwise, use the global flat fee.**

Both branches always return the **global recipient**. Per-currency configs only override the *rate schedule*, not the recipient.

### Global fee

The protocol fee rate is **off by default**: a freshly deployed controller returns 0 fee. Governance can set the recipient and enable a global rate with:

```solidity
controller.setProtocolFeeRecipient(treasury);
controller.setGlobalProtocolFeePips(50_000); // 5% on all currencies
```

To turn the global flat fee off, set `globalProtocolFeePips` to 0. Per-currency schedules must be cleared separately with `setProtocolFeeBracketsForCurrency(currency, new ProtocolFeeBracket[](0))`.

```solidity
controller.setGlobalProtocolFeePips(0);
```

### Per-currency override (optional)

For currencies that warrant a non-flat schedule, governance can install up to `MAX_PROTOCOL_FEE_TIERS` (3) progressive tiers. Progressive means each tier's pips rate only applies to the portion of the amount *within that tier's range* — the same pattern as income tax brackets. No cliff effects, no gaming around thresholds.

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
IProtocolFeeController.ProtocolFeeBracket[] memory tiers = new IProtocolFeeController.ProtocolFeeBracket[](3);
tiers[0] = IProtocolFeeController.ProtocolFeeBracket({ lowerThreshold: 0,     protocolFeePips: 20_000 });
tiers[1] = IProtocolFeeController.ProtocolFeeBracket({ lowerThreshold: 10e18, protocolFeePips: 10_000 });
tiers[2] = IProtocolFeeController.ProtocolFeeBracket({ lowerThreshold: 50e18, protocolFeePips: 5_000  }); // last tier extends to infinity
controller.setProtocolFeeBracketsForCurrency(eth, tiers);
```

Fees on an 80 ETH raise:

```
(10 ETH × 2%) + (40 ETH × 1%) + (30 ETH × 0.5%) = 0.75 ETH  (0.9375% effective)
```

To cap fees beyond a certain amount, spend the final tier slot on a 0-pips tail. Reducing the schedule to two real tiers + cap, so it still fits within `MAX_PROTOCOL_FEE_TIERS`:

```solidity
IProtocolFeeController.ProtocolFeeBracket[] memory tiers = new IProtocolFeeController.ProtocolFeeBracket[](3);
tiers[0] = IProtocolFeeController.ProtocolFeeBracket({ lowerThreshold: 0,      protocolFeePips: 20_000 });
tiers[1] = IProtocolFeeController.ProtocolFeeBracket({ lowerThreshold: 10e18,  protocolFeePips: 10_000 });
tiers[2] = IProtocolFeeController.ProtocolFeeBracket({ lowerThreshold: 100e18, protocolFeePips: 0      }); // cap, no fee beyond 100 ETH
controller.setProtocolFeeBracketsForCurrency(eth, tiers);
```

### Constraints at a glance

| Parameter | Limit | Reason |
| --- | --- | --- |
| Tiers per currency | 3 (`MAX_PROTOCOL_FEE_TIERS`) | Reverts with `InvalidFeeLength` above this. |
| `lowerThreshold` | `uint128` | Lower bound of the bracket in currency base units. |
| `protocolFeePips` | 0–1,000,000 | 100% max (`PIPS_DENOMINATOR`). |
| First tier `lowerThreshold` | must be 0 | Schedule must start at 0. |
| Subsequent `lowerThreshold`s | strictly ascending | Non-overlapping brackets. |
| Last tier | extends to infinity | Its rate applies to all amount above its `lowerThreshold`. |

### Clearing a per-currency override

Call `setProtocolFeeBracketsForCurrency(currency, new ProtocolFeeBracket[](0))` to revert a currency back to the global fee.

### Deployment expectation

`ProtocolFeeController` uses solady's `Ownable` and takes the initial owner as a constructor arg:

```solidity
new ProtocolFeeController(governance);
```

The protocol fee rate is off by default. The expected post-deploy sequence is:

1. Optionally call `setProtocolFeeRecipient(recipient)` and `setGlobalProtocolFeePips(pips)` to turn on the global fee.
2. If the deployer was set as the initial owner, transfer ownership to the governance multisig/timelock.

The fee can be enabled or updated at any time after deployment.

### Notes for integrators

- **Always forward fees to the returned `recipient`.** The recipient is the *global* recipient; per-currency configs do not override it.
- **Events.** `ProtocolFeeRecipientUpdated`, `GlobalProtocolFeePipsUpdated`, and `ProtocolFeeBracketsForCurrencyUpdated` let off-chain indexers reconstruct the current schedule. `getProtocolFeeBracketsForCurrency(currency)` returns the full tier array for a given currency.
