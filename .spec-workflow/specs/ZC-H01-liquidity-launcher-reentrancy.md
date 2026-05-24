# ZC-H01 LiquidityLauncher Reentrancy Mitigation

## Finding

`LiquidityLauncher` holds staged token balances in shared custody while `createToken`, `depositToken`, and
`distributeToken` can enter untrusted external code. A malicious token can reenter during Permit2-backed
`transferFrom` in `depositToken` or during `SafeERC20.forceApprove` in `distributeToken`, then call
`distributeToken` for a different token balance already staged in the launcher.

## Security Objective

Callback-driven reentrancy must not be able to invoke any launcher entrypoint while another launcher entrypoint is
in progress. Normal sequential batching through `multicall` must continue to work because each delegated subcall
finishes and releases the lock before the next subcall starts.

## Requirements

- Add one shared reentrancy guard for `LiquidityLauncher`.
- Apply the guard to `createToken`, `depositToken`, and `distributeToken`.
- Preserve the documented multicall flows:
  - `createToken` followed by `distributeToken`.
  - Permit2 `permit`, `depositToken`, then `distributeToken`.
- Reentrant callbacks during Permit2 token transfer or token approval must revert before an unrelated staged token
  can be approved to an attacker-controlled strategy.
- Use the repository's existing guard style: `ReentrancyGuardTransient`.

## Regression Coverage

Add focused Foundry tests for both reported callback surfaces:

- A malicious ERC20 reenters from `transferFrom` while `depositToken` is executing and attempts to distribute the
  victim token created earlier in the same multicall.
- A malicious ERC20 reenters from `approve` while `distributeToken` is executing and attempts to distribute the
  victim token created earlier in the same multicall.

Both tests must fail on the vulnerable implementation and pass only when the nested launcher call is blocked by the
shared reentrancy guard. The Permit2 transfer path may surface the guard failure through Permit2's token-transfer
failure because the token transfer callback reverts.
