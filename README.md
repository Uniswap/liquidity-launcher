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

The primary distribution strategy is a Liquidity Bootstrapping Pool (LBP) that combines a price discovery auction with automated liquidity provisioning that delivers immediate trading liquidity.

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
forge test --isolate -vvv
```

The project requires the following environment variable for testing:

- `QUICKNODE_RPC_URL`: An Ethereum mainnet RPC endpoint for fork testing

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

### FullRangeLBPStrategyFactory
The FullRangeLBPStrategyFactory contract is deployed to different addresses on different networks as it uses the deployed Position Manager and Pool Manager contracts from Uniswap v4.

| Version | Chain | Address | Commit Hash |
|---------|-------|---------|------------|
| v2.0.0 | Mainnet | 0x65aF3B62EE79763c704f04238080fBADD005B332 | 610603eed7c35ff504e23ec87cd18ec3f701e746  |
| v2.0.0 | Unichain | 0xAa56d4d68646B4858A5A3a99058169D0100b38e2 | 610603eed7c35ff504e23ec87cd18ec3f701e746 |
| v2.0.0 | Base | 0x39E5eB34dD2c8082Ee1e556351ae660F33B04252 | 610603eed7c35ff504e23ec87cd18ec3f701e746 |
| v2.0.0 | Sepolia | 0x89Dd5691e53Ea95d19ED2AbdEdCf4cBbE50da1ff | 610603eed7c35ff504e23ec87cd18ec3f701e746 |
| v2.0.0 | Base Sepolia | 0xa3A236647c80BCD69CAD561ACf863c29981b6fbC | 610603eed7c35ff504e23ec87cd18ec3f701e746 |

### AdvancedLBPStrategyFactory
The AdvancedLBPStrategyFactory contract is deployed to different addresses on different networks as it uses the deployed Position Manager and Pool Manager contracts from Uniswap v4.

| Version | Chain | Address | Commit Hash |
|---------|-------|---------|------------|
| v2.0.0 | Mainnet | 0x982DC187cbeB4E21431C735B01Ecbd8A606129C5 | 610603eed7c35ff504e23ec87cd18ec3f701e746 |
| v2.0.0 | Unichain | 0xeB44195e1847F23D4ff411B7d501b726C7620529 | 610603eed7c35ff504e23ec87cd18ec3f701e746 |
| v2.0.0 | Base | 0x9C5A6fb9B0D9A60e665d93a3e6923bDe428c389a | 610603eed7c35ff504e23ec87cd18ec3f701e746 |
| v2.0.0 | Sepolia | 0xdC3553B7Cea1ad3DAB35cBE9d40728C4198BCBb6 | 610603eed7c35ff504e23ec87cd18ec3f701e746 |
| v2.0.0 | Base Sepolia | 0x67E24586231D4329AfDbF1F4Ac09E081cFD1e6a6 | 610603eed7c35ff504e23ec87cd18ec3f701e746 |

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
