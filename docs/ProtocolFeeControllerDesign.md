# ProtocolFeeController Design

## Overview

The ProtocolFeeController provides a simple, governance-controlled protocol fee. In its default configuration, it applies a single global fee rate and recipient across all currencies — no per-currency setup required.

For currencies that need more granularity, per-currency overrides can be configured with up to 3 progressive fee tiers, a custom scale, and an amount ceiling — all packed into a single storage slot. Per-currency overrides can be cleared at any time to revert to the global fee.

## Global Fee (Default)

The default mode is a flat fee: a single `globalProtocolFeeBps` rate and `globalProtocolFeeRecipient` address, applied uniformly to all currencies. This is sufficient for most use cases and requires no per-currency configuration.

## Per-Currency Progressive Fee (Optional Override)

Fees are calculated using marginal brackets, similar to income tax systems. Each bracket applies its rate only to the portion of the amount within that bracket — not to the full amount.

Example with 3 tiers (scale=18, so 1 unit = 1 ETH):

```
Tier 1: 0 ETH      → 2.00% fee
Tier 2: 10 ETH     → 1.00% fee
Tier 3: 50 ETH     → 0.50% fee
Cap:    100 ETH (no fees charged beyond this amount)

Amount raised: 80 ETH

Fee = (10 ETH × 2.00%) + (40 ETH × 1.00%) + (30 ETH × 0.50%)
    = 0.2 + 0.4 + 0.15
    = 0.75 ETH

Effective rate: 0.75 / 80 = 0.9375%
```

For amounts exceeding the cap, fees are only charged on the portion up to the cap:

```
Amount raised: 150 ETH (cap = 100 ETH)

Fee = (10 ETH × 2.00%) + (40 ETH × 1.00%) + (50 ETH × 0.50%)
    = 0.2 + 0.4 + 0.25
    = 0.85 ETH

Effective rate: 0.85 / 150 = 0.567%
```

The fee plateaus at 0.85 ETH for any amount ≥ 100 ETH. No cliff effects at tier boundaries. No incentive to game amounts around thresholds.

## Storage Layout

Each currency's fee configuration is packed into a single 256-bit storage slot:

```
| 8 bits | 8 bits | 16 bits | 16 bits  | 16 bits | 16 bits  | 16 bits | 16 bits |
| length | scale  | fee1    | start2   | fee2    | start3   | fee3    | cap     |
                                                                         = 112 bits
                                                                  remaining: 144 bits (reserved)
```

### Fields

| Field    | Bits | Range    | Description                                                                            |
| -------- | ---- | -------- | -------------------------------------------------------------------------------------- |
| `length` | 8    | 0-3      | Number of active fee tiers                                                             |
| `scale`  | 8    | 0-72     | Power-of-10 exponent. Defines the unit size: `1 unit = 10^scale` smallest denomination. Capped at 72 to prevent overflow: `uint16 max (65,535) × 10^72 < uint256 max` |
| `fee1`   | 16   | 0-10,000 | Fee rate in bps for the first bracket (starts at amount 0)                             |
| `start2` | 16   | 0-65,535 | Start amount for the second bracket, in scaled units                                   |
| `fee2`   | 16   | 0-10,000 | Fee rate in bps for the second bracket                                                 |
| `start3` | 16   | 0-65,535 | Start amount for the third bracket, in scaled units                                    |
| `fee3`   | 16   | 0-10,000 | Fee rate in bps for the third bracket                                                  |
| `cap`    | 16   | 0-65,535 | Amount ceiling in scaled units. Fees are only charged up to this amount. 0 = no ceiling |

### Scale examples

| Currency | Decimals | Scale | 1 unit =   | uint16 max =    |
| -------- | -------- | ----- | ---------- | --------------- |
| ETH      | 18       | 18    | 1 ETH      | 65,535 ETH      |
| ETH      | 18       | 16    | 0.01 ETH   | 655.35 ETH      |
| USDC     | 6        | 6     | 1 USDC     | 65,535 USDC     |
| UNI      | 18       | 22    | 10,000 UNI | 655,350,000 UNI |

### Tier boundary computation

Tier boundaries are converted to absolute amounts via:

```
threshold = startAmount * 10^scale
```

No fractions or division needed in the lookup — just multiplication and comparison.

## Fee Calculation

The cap is the ceiling of the last bracket. When the loop reads pairs of `(feeBps, nextBoundary)`, the cap naturally serves as the final boundary. Amounts beyond `cap * 10^scale` incur no additional fees.

```
fee = 0
for each tier (i = 0 to length-1):
    bracketStart = tier[i].start * 10^scale
    bracketEnd   = tier[i+1].start * 10^scale  (or cap * 10^scale, if last tier)
    if cap == 0:  bracketEnd = amount           (no ceiling)
    ceiling   = min(amount, bracketEnd)
    fee += (ceiling - bracketStart) * tier[i].feeBps / BPS
    if amount <= bracketEnd:  break
```

## Interface

```solidity
// Returns the computed progressive fee amount for the given currency and amount
function getProtocolFeeAmount(address currency, uint256 amount)
    external view returns (uint256 protocolFeeAmount, address protocolFeeRecipient);

// Returns the effective fee rate in bps for the given currency and amount
// Derived from: effectiveBps = feeAmount * BPS / amount
function getProtocolFeeBps(address currency, uint256 amount)
    external view returns (uint24 protocolFeeBps, address protocolFeeRecipient);
```

Both functions compute the same progressive fee. `getProtocolFeeAmount` is used by the LBP Strategy contract for the actual fee deduction. `getProtocolFeeBps` is used by frontends to display the effective rate to users. When `amount == 0`, `getProtocolFeeBps` returns 0 for the fee rate and the global recipient.

## Global Fee Limitation

When a currency has no per-currency configuration (`length == 0`), the global fee applies as a flat rate on the full amount. The global fee does not support tiers or progressive brackets — a single scale cannot meaningfully represent tier boundaries across currencies with different decimal precisions (e.g., 18 for ETH, 6 for USDC). Per-currency configuration is required for progressive tiers precisely because each currency needs its own scale.

## Design Decisions

- **Progressive over flat tiers** — Eliminates cliff effects at boundaries. More predictable for auction creators. Standard pattern in tax/fee systems.
- **Single slot per currency** — One SLOAD for the full fee schedule. Assembly-packed for gas efficiency.
- **Scale as power-of-10** — Avoids fractional math. Tier boundaries are human-readable. Accommodates different token decimals and values with one 8-bit config field.
- **3 tiers max** — Physical constraint of the slot layout. Sufficient for realistic fee schedules.
- **Cap as amount ceiling** — Fees are only charged on amounts up to the cap. Integrates naturally into the bracket loop as the last boundary — no post-loop clamping needed. Protects large auctions from disproportionate fees. `cap = 0` means no ceiling.
- **144 bits reserved** — Remaining slot space is intentionally unused, available for future extension without layout changes.
