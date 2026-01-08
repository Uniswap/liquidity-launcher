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
- **Deploy** automated market making pools on Uniswap V4

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

# Build the project
forge build

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
The FullRangeLBPStrategyFactory contract can be deployed to the same address on all networks.

| Version | Address | Commit Hash |
|---------|---------|------------|
| v1.1.0 |  |  |

### AdvancedLBPStrategyFactory
The AdvancedLBPStrategyFactory contract can be deployed to the same address on all networks.

| Version | Address | Commit Hash |
|---------|---------|------------|
| v1.1.0 |  |  |

## Audits
- 10/1 [OpenZeppelin](./docs/audit/Uniswap%20Token%20Launcher%20Audit.pdf)
- 10/27 [Spearbit](./docs/audit/report-cantinacode-uniswap-token-launcher-1027.pdf)

### Bug bounty

The files under `src/` are covered under the Uniswap Labs bug bounty program [here](https://cantina.xyz/code/f9df94db-c7b1-434b-bb06-d1360abdd1be/overview), subject to scope and other limitations.

### Security contact

security@uniswap.org

### Whitepaper

The [whitepaper](./docs/whitepaper.pdf) for Liquidity Launcher.

## License
This repository is licensed under the MIT License. See the [LICENSE](./LICENSE) file for details.
