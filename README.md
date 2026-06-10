# Liquidity Launcher

Liquidity Launcher is a comprehensive launch system built on Uniswap V4 that facilitates token creation, distribution, and liquidity bootstrapping.

## Table of Contents
- [Overview](#overview)
- [Installation](#installation)
- [Docs](#docs)
- [Deployment addresses](#deployment-addresses)
- [Audits](#audits)

## Overview
Liquidity Launcher provides a streamlined approach for projects to:
- **Create** new ERC20 tokens with extended metadata and cross-chain capabilities
- **Distribute** tokens through customizable strategies
- **Bootstrap** liquidity using price discovery mechanisms
- **Deploy** automated market making pools on Uniswap v4

The primary strategy is a Liquidity Bootstrapping Pool (LBP) that combines a price discovery auction with automated liquidity provisioning that delivers immediate trading liquidity.

## Installation
This project uses Foundry for development and testing. To get started:

```bash
# Clone the repository with submodules
git clone --recurse-submodules <repository-url>
cd liquidity-launcher

# If you already cloned without submodules
git submodule update --init --recursive

# Install Foundry (if not already installed)
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Install Rust (if not already installed)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
rustup

# Build the project
forge build

# Build rust project
./script/build_rust.sh

# Run tests
forge test

# Run the LBP strategy suite
forge test --match-path 'test/strategies/lbp/**/*.sol'
```

Most tests run locally. The periphery position-recipient tests fork mainnet and require:

- `QUICKNODE_RPC_URL`: An Ethereum mainnet RPC endpoint for fork testing

## LBP Hooks

LBP distributions can configure a Uniswap v4 hook through `MigratorParameters.hook`. Any nonzero hook used in this `hook` field MUST inherit `InitializerHook`. The strategy enforces this by checking ERC165 support for `IInitializerHook` during `initializeDistribution`. `InitializerHook` gates `beforeInitialize` so only the singleton `LBPStrategy` can initialize the committed pool. `GatedSwapHook` already inherits `InitializerHook`.

If `hook` is `address(0)`, the migration destination is state-dependent: `hook = address(0)` means "prefer the hookless pool, but fall back to the strategy-hooked pool if the hookless pool already exists," so it does not guarantee the final pool is hookless. Migration first attempts to initialize the canonical hookless v4 pool `(currency0, currency1, fee, tickSpacing, address(0))`. If that pool was already initialized, `LBPStrategy` falls back to using its own address as the hook and initializes the strategy-hooked pool `(currency0, currency1, fee, tickSpacing, address(strategy))` instead. `LBPStrategy` is deployed at a valid `BEFORE_INITIALIZE` hook address and self-gates `beforeInitialize`, so this fallback does not require a separate `InitializerHook` deployment. The hookless pool is preferred for simpler routing; the strategy-hooked pool only preserves a migration path when the hookless key has already been consumed. See the [Deployment Guide](./docs/DeploymentGuide.md#lbp-hook-requirement) for details.

## Docs
- [Technical Reference](./docs/TechnicalReference.md)
- [Changelog](./CHANGELOG.md)
- [Deployment Guide](./docs/DeploymentGuide.md)

## Deployment Addresses

### Liquidity Launcher
The LiquidityLauncher contract can be deployed to the same address on all networks with the canonical Permit2 deployment address (0x000000000022D473030F116dDEE9F6B43aC78BA3).

| Version | Address | Commit Hash |
|---------|---------|------------|
| v1.0.0 | 0x00000008412db3394C91A5CbD01635c6d140637C | fd5be9b7a918ca3d925d985dff9bcde82b3b8a9d |

> No changes have been made to the LiquidityLauncher contract since v1.0.0.

> The v2.0.0 LBP strategy factories (`FullRangeLBPStrategyFactory`, `AdvancedLBPStrategyFactory`, `GovernedLBPStrategyFactory`) were removed in v3.0.0 and consolidated into a single `LBPStrategy`. Their prior deployment addresses are retained for reference, marked deprecated, in the [Deployment Guide](./docs/DeploymentGuide.md#legacy-deployments-deprecated).

## Audits
- 1/23/2026 [OpenZeppelin](./docs/audit/OpenZeppelin_v2.0.0.pdf)
- 1/21/2026 [Spearbit](./docs/audit/uniswap-liquidity-launcher-v2.0.0.pdf)
- 10/27/2025 [Spearbit](./docs/audit/report-cantinacode-uniswap-token-launcher-1027.pdf)
- 10/20/2025 [ABDK Consulting](./docs/audit/ABDK_Uniswap_TokenLauncher_v_1_0.pdf)
- 10/1/2025 [OpenZeppelin](./docs/audit/Uniswap%20Token%20Launcher%20Audit.pdf)

### Bug bounty

The files under `src/` are covered under the Uniswap Labs bug bounty program [here](https://cantina.xyz/code/f9df94db-c7b1-434b-bb06-d1360abdd1be/overview), subject to scope and other limitations.

### Security contact

security@uniswap.org

### Whitepaper

The [whitepaper](./docs/whitepaper.pdf) for Liquidity Launcher.

## License
This repository is licensed under the MIT License. See the [LICENSE](./LICENSE) file for details.
