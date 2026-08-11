# Periphery

Peripheral contracts used alongside launch strategies.

## Contents

| Contract | Purpose |
| --- | --- |
| [`BaseClaimRecipient`](./BaseClaimRecipient.sol) | Abstract base for LP position fee recipients: attributes received amounts per position (`onAmountsReceived`), pays them out through `claim(tokenId, min0, min1)`, pulls from other `IClaimableRecipient`s through permissionless `claimFrom(source, tokenId, …)`, and lets subclasses set the payout policy via `_beforeClaimTransfer`. |
| [`BaseClaimRecipientWithCallback`](./BaseClaimRecipientWithCallback.sol) | A `BaseClaimRecipient` whose `claim` unconditionally calls the caller back through `IClaimExecutor.onClaimed`, bracketed by before/after hooks so the subclass can enforce what the executor must do with the funds. |
| [`FeeSplitter`](./FeeSplitter.sol) | Singleton, zero-admin custodian of v4 native-ETH LP positions. Permissionless `collectFees(tokenIds[])` pushes immutable, independent bps splits of native ETH and token fees; native shares are force-sent. A recipient that reverts its callback reverts the whole call, so callers should exclude such token IDs — the skipped fees stay collectable in the pool. `currency1` must be a standard, unrestricted token. Positions are irrecoverable by design. |
| [`BeneficiaryVault`](./BeneficiaryVault.sol) | A `BaseClaimRecipient` with transferable beneficiary NFTs. `registerBeneficiary(tokenId, beneficiary)` is authorized by position custody, so depositors register BEFORE transferring the position away. Only the NFT owner may claim attributed amounts; unregistered shares pay out to immutable per-side fallbacks. |
| [`UERC20BeneficiaryVault`](./UERC20BeneficiaryVault.sol) | A `BeneficiaryVault` for positions whose custodian never registered a beneficiary (e.g. strategies that predate the vault). The creator of the launcher-created UERC20 in the pair proves themselves through the token's `graffiti()`; the first proven claim mints them the beneficiary NFT, and later claims use the base's plain owner check. An unregistered position pairing such a token reverts for anyone else rather than flushing the creator's share to the fallbacks. Do NOT use it for pools pairing two tokens that both expose `graffiti()`: either creator passes the check, and whichever claims first takes both currency sides. |
| [`BuybackAndBurnClaimRecipient`](./BuybackAndBurnClaimRecipient.sol) | Callback recipient for native-ETH-paired positions: `claim` pays the attributed amounts to the caller, invokes `onClaimed` (during which the caller may perform a buyback), then pulls `minCurrency1BurnAmount` of the position's `currency1` from the caller and sends it to the burn address. Designed so MEV searchers can profitably trigger buyback-and-burns. |
| [`CompoundingClaimRecipient`](./CompoundingClaimRecipient.sol) | Callback recipient that requires the claimed position's liquidity to grow by at least `minLiquidityIncrease` across the executor callback. The executor performs the deposit and liquidity increase; the recipient only snapshots and verifies. |
| [`VestingClaimRecipient`](./VestingClaimRecipient.sol) | Rate-limiting middle hop. Custodies beneficiary NFTs so it becomes the only party a vault will pay, drains them through permissionless `claimFrom(source, tokenId, …)`, then releases at most `maxCurrencyPerBlock` per claim, at most once per block per position, to a recipient fixed at deploy. The cap does not accrue across unclaimed blocks. It bounds one position's rate, not the contract's aggregate rate across positions. |
| [`TimelockedPositionRecipient`](./TimelockedPositionRecipient.sol) | Holds v4 LP positions until a timelock block is reached, after which anyone can approve the configured operator to transfer them. |
| [`ProtocolFeeController`](./ProtocolFeeController.sol) | Governance-controlled source of truth for the protocol fee applied to currency raised by a launch. Integrators call it at fee-settlement time to discover the fee amount and recipient. See below. |
| [`InitializerHook`](./hooks/InitializerHook.sol) | Base v4 hook that restricts pool initialization to a preset address. Any nonzero hook configured in `MigratorParameters.poolParameters.hook` MUST inherit it. |
| [`GatedSwapHook`](./hooks/GatedSwapHook.sol) | An `InitializerHook` that also blocks swaps until a configured gatekeeper calls `approveSwaps()`. |
| [`SelfInitializerMixin`](../strategies/lbp/SelfInitializerMixin.sol) | Abstract mixin for hooks that only initialize their own pools: it reverts every `beforeInitialize` callback, relying on v4 skipping the callback when the sender is the hook itself. |

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
