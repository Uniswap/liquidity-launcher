# Liquidity Launcher

Liquidity Launcher is a comprehensive launch system built on Uniswap v4 that facilitates token creation, distribution, and liquidity bootstrapping.

## Table of Contents

- [Overview](#overview)
- [Installation](#installation)
- [LBP Hooks](#lbp-hooks)
- [Docs](#docs)
- [Deployment Addresses](#deployment-addresses)
  - [Core](#core)
  - [Periphery](#periphery)
- [Audits](#audits)
- [License](#license)

## Overview

Liquidity Launcher provides a streamlined approach for projects to:

- **Create** new ERC20 tokens with extended metadata and cross-chain capabilities
- **Distribute** tokens through customizable strategies
- **Bootstrap** liquidity using price discovery mechanisms
- **Deploy** automated market making pools on Uniswap v4

The primary strategy is a Liquidity Bootstrapping Pool (LBP) that combines a price discovery auction with automated liquidity provisioning that delivers immediate trading liquidity.

The repository also includes several direct strategies:

- `InstantLaunchStrategy` launches a fixed-supply token directly into a hookless native-ETH v4 pool as a single-sided position, permanently locked in the `FeeSplitter` for permissionless fee distribution.
- `UniversalRouterStrategy` runs a caller-supplied Universal Router route, so a launch and a buy fit in one transaction.
- `TokenSplitter` splits a distribution across N recipients without taking custody.
- `MerkleClaimFactory` deploys and funds a `MerkleClaim` (Uniswap's audited merkle distributor) for claim-based distributions.

See the [Technical Reference](./docs/TechnicalReference.md#distribution-strategies) for configuration, lifecycle, and trust assumptions.

## Installation

This project uses Foundry for development and testing. To get started:

```bash
# Clone the repository with submodules
git clone --recurse-submodules <repository-url>
cd token-launcher

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

- `QUICKNODE_RPC_URL` — an Ethereum mainnet RPC endpoint for fork testing

## LBP Hooks

LBP distributions can configure a Uniswap v4 hook through `MigratorParameters.poolParameters.hook`. Any nonzero hook MUST inherit `InitializerHook`, which gates `beforeInitialize` so only the singleton `LBPStrategy` can initialize the committed pool; the strategy verifies this via ERC165 during `initializeDistribution`. `GatedSwapHook` already inherits `InitializerHook`.

If `hook` is `address(0)` (static-fee pools only), the migration destination is state-dependent: migration prefers the canonical hookless pool, but falls back to the strategy-hooked pool `(..., address(strategy))` if the hookless key was already initialized. Integrators should resolve the actual pool key from the `Migrated` event rather than assuming `address(0)`. See the [Deployment Guide](./docs/DeploymentGuide.md#lbp-hook-requirement) for details.

## Docs

- [Technical Reference](./docs/TechnicalReference.md)
- [Deployment Guide](./docs/DeploymentGuide.md)
- [Changelog](./CHANGELOG.md)
- [Whitepaper](./docs/whitepaper.pdf)

## Deployment Addresses

Canonical contract addresses by chain and version. Cross-references link to related deployments elsewhere in this section.

> Prior deployment addresses are retained for reference, marked deprecated, in the [Deployment Guide](./docs/DeploymentGuide.md#legacy-deployments-deprecated).

### Core

#### Liquidity Launcher

Deployed to the same address on all networks that use the canonical Permit2 deployment (`0x000000000022D473030F116dDEE9F6B43aC78BA3`).

| Version | Chain | Address | Commit Hash |
| --- | --- | --- | --- |
| v3.0.0 | | `0x00004c4ccc709Ef590F7C81102C0689F0263D4e9` | `3a3103543f50a13a0ae52a253bb98a925d72146f` |
| v3.2.0 | Robinhood Chain | `0x0000FffFBE8efE702c8703aE3477FF5dE3d319C0` | `dd8769cd45c0e9450e928513ee129b0af74f7f32` |

#### LBPStrategy

Deployed to a different address on each chain. Must be deployed to a valid v4 hook address.

| Version | Chain | Address | Commit Hash |
| --- | --- | --- | --- |
| v3.1.0 | Mainnet | `0x49380c4EfaB1b491006aF7FabAB8B3459F0E6000` | `873cbb23c5019a795193c5ad561edff2f78ba5a3` |
| v3.1.0 | Base | `0x34385dD739FE5464892BF0bA4CC42492804dA000` | `873cbb23c5019a795193c5ad561edff2f78ba5a3` |
| v3.1.0 | Unichain | `0x298eA05D0356B2Ae5cCAa3169E471783ee9EA000` | `873cbb23c5019a795193c5ad561edff2f78ba5a3` |
| v3.1.0 | Arbitrum | `0x8Af0775a70Cc94D71DFc0fE809435e833F2Fe000` | `873cbb23c5019a795193c5ad561edff2f78ba5a3` |
| v3.1.1 | Robinhood Chain | `0x05d552391067389EE44fec3924157ed33F976000` | `5ef0262b8e191360a212aac864a525dcf7a06605` |
| v3.1.0 | Avalanche | `0x57BD0A9Cd933c89Ba55e086D53031367b6406000` | `873cbb23c5019a795193c5ad561edff2f78ba5a3` |
| v3.1.0 | XLayer | `0x58DF162fF41e5cB42B8515f75F90C1841938A000` | `873cbb23c5019a795193c5ad561edff2f78ba5a3` |
| v3.1.0 | Sepolia | `0x96641d91e223c766F45b19d09494F5925C3cE000` | `873cbb23c5019a795193c5ad561edff2f78ba5a3` |
| v3.1.0 | Base Sepolia | `0xB06428b62c259eE982cE3D9BED47391dC9A5E000` | `873cbb23c5019a795193c5ad561edff2f78ba5a3` |

#### InstantLaunchStrategy

Deployed to a different address on each chain. Multiple versions may exist; each pins to a specific [Fee Splitter](#fee-splitter).

| Version | Chain | Address | Fee Splitter | Commit Hash |
| --- | --- | --- | --- | --- |
| v3.2.0 | Robinhood Chain | `0x23f8209572b4a1C2AD88A42749E830791Fb027f1` | [`0xeFF166AAf189323c58dc27eD1206EB2C37FaACDf`](#fee-splitter) | `dd8769cd45c0e9450e928513ee129b0af74f7f32` |
| v3.2.0 | Robinhood Chain | `0xAD44D55E7f8337C3cE113fBb591486E85be104b2` | [`0x222D6d4f1ce59b0d48D5505114eC8Addc90A4359`](#fee-splitter) | `dd8769cd45c0e9450e928513ee129b0af74f7f32` |

#### UniversalRouterStrategy

Deployed to a different address on each chain. Runs a caller-supplied Universal Router route so a launch and a buy can fit in one transaction.

| Version | Chain | Address | Commit Hash |
| --- | --- | --- | --- |
| v3.2.0 | Robinhood Chain | `0x1242c9439d589cAE85E121B1f79f2aF51e91DCEE` | `dd8769cd45c0e9450e928513ee129b0af74f7f32` |

#### TokenSplitter

Deployed to the same address on all networks.

| Version | Chain | Address | Commit Hash |
| --- | --- | --- | --- |
| v3.0.0 | | `0x8B7DCeb5639DB986FCf86606C74e6300C40FE3cd` | `3a3103543f50a13a0ae52a253bb98a925d72146f` |
| v3.2.0 | Robinhood Chain | `0x4F5E3FBb9745358A92Da5674305FAb8D2B8a73cE` | `dd8769cd45c0e9450e928513ee129b0af74f7f32` |

### Periphery

#### Fee Splitter

Deployed per chain with immutable fee splits. Multiple deployments may exist on the same chain.

| Version | Chain | Address | Fee Splits | Commit Hash |
| --- | --- | --- | --- | --- |
| v3.2.0 | Robinhood Chain | `0xeFF166AAf189323c58dc27eD1206EB2C37FaACDf` | [UERC20BeneficiaryVault](#uerc20beneficiaryvault): 40% native ETH; [CompoundingClaimRecipient](#compoundingclaimrecipient): 60% native ETH, 100% token | `dd8769cd45c0e9450e928513ee129b0af74f7f32` |
| v3.2.0 | Robinhood Chain | `0x222D6d4f1ce59b0d48D5505114eC8Addc90A4359` | [CompoundingClaimRecipient](#compoundingclaimrecipient): 100% native ETH, 100% token | `dd8769cd45c0e9450e928513ee129b0af74f7f32` |

#### UERC20BeneficiaryVault

Deployed to a different address on each chain. Distributes and attributes creator fees.

| Version | Chain | Address | Commit Hash |
| --- | --- | --- | --- |
| v3.2.0 | Robinhood Chain | `0xd35E9CA72F64C7F93BE30fad67524323396B36D7` | `dd8769cd45c0e9450e928513ee129b0af74f7f32` |

#### CompoundingClaimRecipient

Deployed to a different address on each chain. Permissionlessly compounds LP fees into liquidity.

| Version | Chain | Address | Commit Hash |
| --- | --- | --- | --- |
| v3.2.0 | Robinhood Chain | `0xf9526Dd3361fe0ba6b7a99533ed471D3E808E99a` | `dd8769cd45c0e9450e928513ee129b0af74f7f32` |

#### InitializerHook

Restricts pool initialization to a deployed LBPStrategy instance.

| Version | Chain | Address | LBPStrategy | Salt | Commit Hash |
| --- | --- | --- | --- | --- | --- |
| v3.1.1 | Robinhood Chain | `0xD462a559337859369EF271814851A18F496ba000` | [`0x05d552391067389EE44fec3924157ed33F976000`](#lbpstrategy) | `0x0000000000000000000000000000000000000000000000000000000000002dcb` | `5ef0262b8e191360a212aac864a525dcf7a06605` |

## Audits

| Date | Auditor | Report |
| --- | --- | --- |
| 2026-01-23 | OpenZeppelin | [v2.0.0](./docs/audit/OpenZeppelin_v2.0.0.pdf) |
| 2026-01-21 | Spearbit | [v2.0.0](./docs/audit/uniswap-liquidity-launcher-v2.0.0.pdf) |
| 2025-10-27 | Spearbit | [Cantina](./docs/audit/report-cantinacode-uniswap-token-launcher-1027.pdf) |
| 2025-10-20 | ABDK Consulting | [v1.0](./docs/audit/ABDK_Uniswap_TokenLauncher_v_1_0.pdf) |
| 2025-10-01 | OpenZeppelin | [v1.0](./docs/audit/Uniswap%20Token%20Launcher%20Audit.pdf) |

### Bug bounty

The files under `src/` are covered under the Uniswap Labs bug bounty program on [Cantina](https://cantina.xyz/code/f9df94db-c7b1-434b-bb06-d1360abdd1be/overview), subject to scope and other limitations.

### Security contact

[security@uniswap.org](mailto:security@uniswap.org)

## License

This repository is licensed under the MIT License. See [LICENSE](./LICENSE) for details.
