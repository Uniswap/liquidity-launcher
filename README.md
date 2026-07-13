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
| v3.0.0 | 0x00004c4ccc709Ef590F7C81102C0689F0263D4e9 | 3a3103543f50a13a0ae52a253bb98a925d72146f |

### LBPStrategy
The LBPStrategy contract is deployed to a different address on each chain. It must be deployed to a valid v4 hook address.

| Version | Chain | Address | Commit Hash |
|---------|-------|---------|------------|
| v3.1.0 | Mainnet | 0x49380c4EfaB1b491006aF7FabAB8B3459F0E6000 | 873cbb23c5019a795193c5ad561edff2f78ba5a3 |
| v3.1.0 | Base | 0x34385dD739FE5464892BF0bA4CC42492804dA000 | 873cbb23c5019a795193c5ad561edff2f78ba5a3 |
| v3.1.0 | Unichain | 0x298eA05D0356B2Ae5cCAa3169E471783ee9EA000 | 873cbb23c5019a795193c5ad561edff2f78ba5a3 |
| v3.1.0 | Arbitrum | 0x8Af0775a70Cc94D71DFc0fE809435e833F2Fe000 | 873cbb23c5019a795193c5ad561edff2f78ba5a3 |
| v3.1.0 | Robinhood Chain | 0x05d552391067389EE44fec3924157ed33F976000 | 873cbb23c5019a795193c5ad561edff2f78ba5a3 |
| v3.1.0 | Avalanche | 0x57BD0A9Cd933c89Ba55e086D53031367b6406000 | 873cbb23c5019a795193c5ad561edff2f78ba5a3 |
| v3.1.0 | XLayer | 0x58DF162fF41e5cB42B8515f75F90C1841938A000 | 873cbb23c5019a795193c5ad561edff2f78ba5a3 |
| v3.1.0 | Sepolia | 0x96641d91e223c766F45b19d09494F5925C3cE000 | 873cbb23c5019a795193c5ad561edff2f78ba5a3 |
| v3.1.0 | Base Sepolia | 0xB06428b62c259eE982cE3D9BED47391dC9A5E000 | 873cbb23c5019a795193c5ad561edff2f78ba5a3 |

> Prior deployment addresses are retained for reference, marked deprecated, in the [Deployment Guide](./docs/DeploymentGuide.md#legacy-deployments-deprecated).

### InitializerHook
InitializerHooks are simple hooks which restrict pool initialization to a deployed LBPStrategy instance. 

| Version | Chain | Address | LBPStrategy Address | Salt |Commit Hash |
|---------|-------|---------|---------|---------|------------|
| v3.0.0 | Robinhood Chain | 0xD462a559337859369EF271814851A18F496ba000 | 0x05d552391067389EE44fec3924157ed33F976000 | 0x0000000000000000000000000000000000000000000000000000000000002dcb | 873cbb23c5019a795193c5ad561edff2f78ba5a3 |

### TokenSplitter
The TokenSplitter contract is deployed to the same address on all networks.

| Version | Address | Commit Hash |
|---------|---------|------------|
| v3.0.0 | 0x8B7DCeb5639DB986FCf86606C74e6300C40FE3cd | 3a3103543f50a13a0ae52a253bb98a925d72146f |

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
