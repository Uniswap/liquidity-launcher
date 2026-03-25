# PositionPlanner Implementation Plan

## Summary

This refactor replaces the current LBPStrategy-specific position-planning flow with a generic `PositionPlanner` library. The library is not specific to TokenLauncher or LBPStrategies. Its job is to take a known initialized price, explicit `currency0` and `currency1` budgets, and an ordered list of position configurations, then produce the discrete mint parameters needed for the Uniswap v4 `PositionManager`.

The planner computes the maximum feasible allocation across the provided position configurations under fixed token constraints. It resolves final tick bounds, computes token-consumption coefficients per unit liquidity, solves for the largest allocation that fits within the provided balances, rounds deterministically, and admits positions in configuration order. Earlier positions always have priority. Later positions are skipped if they become invalid or exceed remaining balances or per-tick liquidity caps. No redistribution is performed across skipped positions.

## Key Changes

- Consolidate `ActionsBuilder`, `ParamsBuilder`, and `StrategyPlanner` into a single `PositionPlanner` library.
- Make the planner generic over `PoolKey`, initialized price, and `currency0/currency1` budgets.
- Move away from one contract implementation per LP shape.
- Express the LP setup directly in deployment parameters through `PositionParams[]`.
- Keep LBPStrategy responsible for deriving migration budgets and any caller-specific cleanup flow, but delegate discrete position construction to `PositionPlanner`.

## Public Interfaces / Types

### Shared inputs

```solidity
PoolKey poolKey;
uint160 initialSqrtPriceX96;
uint128 currency0Amount;
uint128 currency1Amount;
address positionRecipient;
```

### PositionParams

```solidity
struct PositionParams {
    uint24 allocationMps;  // 1e7 = 100%, or type(uint24).max as a sentinel
    int24 offsetLower;     // absolute offset below current tick
    int24 offsetUpper;     // absolute offset above current tick
}
```

### Planner entrypoint

```solidity
function create(
    PoolKey memory poolKey,
    uint160 initialSqrtPriceX96,
    uint128 currency0Amount,
    uint128 currency1Amount,
    address positionRecipient,
    PositionParams[] calldata params
) internal view returns (Plan memory plan, uint128 used0, uint128 used1);
```

`create` returns the low-level `Plan` for the `PositionManager` plus the final token usage so callers can handle any residual balances in a caller-specific way.

## Allocation Semantics

- `offsetLower` and `offsetUpper` are interpreted as absolute distances from the raw initialized tick.
- For a normal range:
  - `rawLower = currentTick - offsetLower`
  - `rawUpper = currentTick + offsetUpper`
- The pair `offsetLower == MIN_TICK` and `offsetUpper == MAX_TICK` is a full-range sentinel.
- `allocationMps` expresses a fixed share of the planned liquidity shape in millionths of 100%.
- If no sentinel allocation is present, the sum of all `allocationMps` values must equal `1e7`.
- A single `allocationMps == type(uint24).max` entry is allowed as a sentinel meaning "use all remaining funds".
- If a sentinel entry is present:
  - it must be the last entry in config order
  - all non-sentinel `allocationMps` values must sum to at most `1e7`
  - it is treated as a final catch-all position sized from the remaining balances after all fixed-share positions have been processed

## Deterministic Algorithm

1. Derive the raw initialized tick from `initialSqrtPriceX96`.
2. Resolve each `PositionParams` entry in config order:
   - full-range sentinel resolves to `minUsableTick(poolKey.tickSpacing)` and `maxUsableTick(poolKey.tickSpacing)`
   - otherwise resolve `rawLower = currentTick - offsetLower` and `rawUpper = currentTick + offsetUpper`
3. Snap resolved ranges to valid ticks:
   - `lower = floor(rawLower, tickSpacing)`
   - `upper = ceil(rawUpper, tickSpacing)`
4. Immediately skip any position that is invalid after resolution:
   - out of bounds
   - `lower >= upper`
   - zero fixed allocation
5. Partition the positions into:
   - fixed-share positions
   - optional final catch-all sentinel
6. For each fixed-share position, compute token0 and token1 required per unit of liquidity at `initialSqrtPriceX96` using standard concentrated-liquidity math.
7. Use the fixed-share `allocationMps` values as the weights in the global allocation solve.
8. Compute the aggregate coefficients:
   - `A0 = Σ(allocationMps_i * coeff0_i)`
   - `A1 = Σ(allocationMps_i * coeff1_i)`
9. Solve for the maximum continuous scale factor that fits within `currency0Amount` and `currency1Amount`.
10. Convert each fixed-share position into an ideal liquidity amount and round it down deterministically to integer on-chain liquidity.
11. Run an ordered acceptance pass over the fixed-share positions:
   - track accumulated `used0`, `used1`
   - track accumulated liquidity gross at each lower and upper boundary tick
   - accept a position only if adding it would:
     - keep token usage within remaining balances
     - keep both boundary ticks within `maxLiquidityPerTick`
     - still produce nonzero integer liquidity
12. If a fixed-share position fails any acceptance check, skip it and continue. Do not rescale any previously accepted position.
13. If a final catch-all sentinel exists, size it from the remaining `currency0` and `currency1` balances directly in its resolved range using the standard Uniswap liquidity formula for the remaining balances.
14. Accept the sentinel only if it resolves to a valid nonzero position and does not violate `maxLiquidityPerTick` when added to the accumulated accepted set.
15. Build a `Plan` containing only the accepted positions, in accepted-order, using consolidated action/parameter encoding inside `PositionPlanner`.
16. Return the `Plan` and final `used0` / `used1`. The caller remains responsible for any post-plan cleanup or sweeping of residual balances.

## Validation Rules

- Configuration order is authoritative and defines priority.
- Earlier accepted positions are never reduced or removed to accommodate later positions.
- Skipped positions do not trigger recomputation of earlier allocations.
- The planner must apply the same snapping and rounding rules in all environments.
- Boundary-price behavior must match native Uniswap math exactly; the planner should not introduce custom branch rules.
- No deduplication pass is required for multiple entries that resolve to identical bounds.

## Test Plan

- Resolve normal and full-range sentinel positions against a known initialized tick.
- Verify lower-bound floor and upper-bound ceil snapping.
- Verify coefficient computation for below-range, in-range, and above-range positions.
- Verify deterministic scale-factor computation across multiple fixed-share positions.
- Verify deterministic downward rounding of ideal liquidity.
- Verify ordered skipping when a later position exceeds:
  - remaining `currency0`
  - remaining `currency1`
  - `maxLiquidityPerTick`
- Verify skipping does not rescale earlier accepted positions.
- Verify final catch-all sentinel consumes only the remaining balances and does not back-propagate changes to fixed-share positions.
- Verify `create` returns a `Plan` that mints only the accepted positions and reports the correct `used0` / `used1`.

## Assumptions and Defaults

- This is a first-principles refactor and is not constrained by the current LBPStrategy implementation details.
- `PositionPlanner` is generic and should not encode caller-specific sweep or cleanup behavior.
- `offsetLower` and `offsetUpper` are absolute distances from the current tick, not signed deltas.
- At most one `allocationMps == type(uint24).max` sentinel is supported, and it must be last.
- Earlier positions win; skipped later positions leave residual balances unused unless an explicit final sentinel consumes them.
- Residual dust and small deviations from ideal real-number allocations are acceptable as long as outputs are deterministic and balances are never exceeded.
