# Periphery scripts

Deployment and operations scripts for the contracts in [`src/periphery`](../../../src/periphery).

| Script | Purpose |
| --- | --- |
| [`DeployBeneficiaryVault.s.sol`](./DeployBeneficiaryVault.s.sol) | Deploys a `BeneficiaryVault`. |
| [`DeployCompoundingClaimRecipient.s.sol`](./DeployCompoundingClaimRecipient.s.sol) | Deploys a `CompoundingClaimRecipient`. |
| [`DeployCreatorClaimRecipient.s.sol`](./DeployCreatorClaimRecipient.s.sol) | Deploys a `CreatorClaimRecipient`. |
| [`DeployFeeSplitter.s.sol`](./DeployFeeSplitter.s.sol) | Deploys a `FeeSplitter` with the default splits. |
| [`DeployInitializerHook.s.sol`](./DeployInitializerHook.s.sol) | Deploys an `InitializerHook` at a valid v4 hook address. |
| [`CollectAndCompoundFees.s.sol`](./CollectAndCompoundFees.s.sol) | Collects a position's fees and compounds the `CompoundingClaimRecipient`'s share back into it. |
| [`CompoundingClaimExecutor.sol`](./CompoundingClaimExecutor.sol) | The `IClaimExecutor` the script above deploys and calls. Not a protocol contract. |

## Collecting and compounding fees

`CompoundingClaimRecipient.claim` cannot be triggered from an EOA. It pays its caller, calls back into
it through `IClaimExecutor.onClaimed`, and then asserts the position's liquidity grew by at least
`MIN_LIQUIDITY_INCREASE`. Whoever claims has to be a contract that puts the money back into the
position — `CompoundingClaimExecutor` is that contract.

The collect and the compound also have to land in the **same transaction**.
`FeeSplitter.increaseLiquidity` reverts with `UncollectedFees` as soon as the position has accrued
anything since its last modification, so a collect from an earlier block is already stale on any pool
that trades. `collectAndCompound` does both in one call.

### Running it

```bash
export FEE_SPLITTER=0x...                 # FeeSplitter custodying the position
export COMPOUNDING_CLAIM_RECIPIENT=0x...  # recipient holding the compounding split
export TOKEN_IDS=107192,107193            # or TOKEN_ID=107192 for a single position

# Dry run: simulates the full collect and compound against live state.
forge script script/contracts/periphery/CollectAndCompoundFees.s.sol --rpc-url "$RPC_URL"

# Execute.
forge script script/contracts/periphery/CollectAndCompoundFees.s.sol --rpc-url "$RPC_URL" --broadcast
```

The first broadcast CREATE2-deploys the executor; later runs with the same `FEE_SPLITTER`,
`COMPOUNDING_CLAIM_RECIPIENT` and `LIQUIDITY_BUFFER_BPS` reuse it at the same address. Set
`CLAIM_EXECUTOR` to point at an existing one instead.

Optional environment:

| Variable | Default | Meaning |
| --- | --- | --- |
| `CLAIM_EXECUTOR` | CREATE2 address | Reuse a specific executor rather than deploying one. |
| `LIQUIDITY_BUFFER_BPS` | `1` | Basis points withheld from the computed liquidity, absorbing the rounding between `getLiquidityForAmounts` and the amounts the pool charges. Capped at 100 (1%). |
| `MIN_CURRENCY0_AMOUNT` | `0` | Revert unless at least this much currency0 is attributed to the position. |
| `MIN_CURRENCY1_AMOUNT` | `0` | Revert unless at least this much currency1 is attributed to the position. |

### Expected reverts

- `NotEnoughLiquidityAdded(required, actual)` — the collected fees do not buy the recipient's
  `MIN_LIQUIDITY_INCREASE`. Wait for more fees to accrue. `CompoundingClaimExecutor.previewLiquidity`
  reports what the currently attributed amounts would buy, so a keeper can check before submitting.
- `UncollectedFees(tokenId)` — only reachable if something realizes fees between the collect and the
  increase; `collectAndCompound` keeps them adjacent to avoid it.
- `NotOwner(tokenId)` — the `FeeSplitter` does not custody the position.

### What the executor holds

Nothing between transactions. Everything the recipient pays it is either settled into the position or
swept back to the `FeeSplitter`, where the next collect flushes it through the splits.
