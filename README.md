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

| Version | Address | Commit Hash |
| --- | --- | --- |
| v3.2.0 | `0x0000FffFBE8efE702c8703aE3477FF5dE3d319C0` | `dd8769cd45c0e9450e928513ee129b0af74f7f32` |

#### LBPStrategy

Deployed to a different address on each chain. Must be deployed to a valid v4 hook address. Compatible with any Liquidity Launcher of the same major version.

| Version | Chain | Address | Commit Hash |
| --- | --- | --- | --- |
| v3.3.0 | Mainnet | `0x2EEF0e2a9a652d755AccAD95a24541A98B5CA000` | `1c5904912aefceaceb89c24528cd5e25d0b61597` |
| v3.3.0 | Base | `0xf10124B01E9fa88b0a2eF3fA95a53B3310446000` | `1c5904912aefceaceb89c24528cd5e25d0b61597` |
| v3.3.0 | Unichain | `0x48F55E7E8ac229aA4e2f3F2d44aa9284D86da000` | `1c5904912aefceaceb89c24528cd5e25d0b61597` |
| v3.3.0 | Arbitrum | `0xc80f3f4497CD9ae41bf8cB5C8809620182B6E000` | `1c5904912aefceaceb89c24528cd5e25d0b61597` |
| v3.3.0 | Robinhood Chain | `0xbf1aB81f7d534b2CC0Da76fcf4d541322bB0e000` | `1c5904912aefceaceb89c24528cd5e25d0b61597` |
| v3.3.0 | Avalanche | `0x7575c9488AB7913e7749B9F5e02789355699E000` | `1c5904912aefceaceb89c24528cd5e25d0b61597` |
| v3.3.0 | XLayer | `0xde758D7B3202b7f4f842E8313Fc04Bf19c6Be000` | `1c5904912aefceaceb89c24528cd5e25d0b61597` |
| v3.3.0 | Ink | `0x0cB98d78be96D5119E49664a9F24fDA22f83E000` | `1c5904912aefceaceb89c24528cd5e25d0b61597` |
| v3.3.0 | Arc | `0x542BCDA1015485ef0B1cD11B835DC58DF5102000` | `1c5904912aefceaceb89c24528cd5e25d0b61597` |
| v3.3.0 | Sepolia | `0x95434E898Af471945Cab33D5064d2aC1A6Ba2000` | `1c5904912aefceaceb89c24528cd5e25d0b61597` |
| v3.3.0 | Base Sepolia | `0x73ad52384798AdADfBe19fCfD28ff09D2CC82000` | `1c5904912aefceaceb89c24528cd5e25d0b61597` |

#### InstantLaunchStrategy

Deployed to a different address on each chain. Multiple versions may exist; each pins to a specific [Fee Splitter](#fee-splitter).

| Version | Chain | Address | Fee Splitter | Initial Tick | Commit Hash |
| --- | --- | --- | --- | --- | --- |
| v3.3.0 | Robinhood Chain | `0x7c48DDe3B447381F4d986334679b3Afc7F2D35C2` | [`0x9411fa7F956f64aa7981AA27cB3bC6eC0415449C`](#fee-splitter) |`198,050` | `1c5904912aefceaceb89c24528cd5e25d0b61597` |
| v3.3.0 | Robinhood Chain | `0xC9566675b1Ea42861546f3c5B74Ace2c79c49572` | [`0x882Ae5e2095435A62Fd1BBDEfcb637f5CeAFc0ee`](#fee-splitter) |`198,050` | `1c5904912aefceaceb89c24528cd5e25d0b61597` |
| v3.3.0 | Arc | `0x58E5099f22008bc280152c13b636c88d0fE3E132` | [`0xdaA7C2e833Ba71a206f56276b58926A33fB37C33`](#fee-splitter) | `122,050` | `214b8a69bc76f78766ff7d71ceb68209a92f35f7` |
| v3.3.0 | Arc | `0x36F8c87047b212589eD66524Bb69cE62B1f00B2d` | [`0xE8113a9a9CddD6d13fe8A3E32eAA687e108C4616`](#fee-splitter) | `122,050` | `214b8a69bc76f78766ff7d71ceb68209a92f35f7` |

#### UniversalRouterStrategy

Deployed to a different address on each chain. Runs a caller-supplied Universal Router route so a launch and a buy can fit in one transaction.

| Version | Chain | Address | Commit Hash |
| --- | --- | --- | --- |
| v3.3.0 | Robinhood Chain | `0x0A122717bc36E3C7A7958128a5C789E0b070b3Ae` | `1c5904912aefceaceb89c24528cd5e25d0b61597` |
| v3.3.0 | Arc | `0x0A122717bc36E3C7A7958128a5C789E0b070b3Ae` | `1c5904912aefceaceb89c24528cd5e25d0b61597` |

#### TokenSplitter

Deployed to the same address on all networks.

| Version | Chain | Address | Commit Hash |
| --- | --- | --- | --- |
| v3.0.0 | | `0x8B7DCeb5639DB986FCf86606C74e6300C40FE3cd` | `3a3103543f50a13a0ae52a253bb98a925d72146f` |

### Periphery

#### Fee Splitter

Deployed per chain with immutable fee splits. Multiple deployments may exist on the same chain.

| Version | Chain | Address | Fee Splits | Commit Hash |
| --- | --- | --- | --- | --- |
| v3.3.0 | Robinhood Chain | `0x9411fa7F956f64aa7981AA27cB3bC6eC0415449C` | [UERC20BeneficiaryVault](#uerc20beneficiaryvault): 40% native ETH; [CompoundingClaimRecipient](#compoundingclaimrecipient): 60% native ETH, 100% token | `7ea523c9d75a51cb2f497be5e49bacdaeb80a342` |
| v3.3.0 | Robinhood Chain | `0x882Ae5e2095435A62Fd1BBDEfcb637f5CeAFc0ee` | [CompoundingClaimRecipient](#compoundingclaimrecipient): 100% native ETH, 100% token | `7ea523c9d75a51cb2f497be5e49bacdaeb80a342` |
| v3.3.0 | Arc | `0xdaA7C2e833Ba71a206f56276b58926A33fB37C33` | [UERC20BeneficiaryVault](#uerc20beneficiaryvault): 40% native ETH; [BuybackAndBurnRecipient](#buybackandburnrecipient): 60% native ETH, 100% token | `214b8a69bc76f78766ff7d71ceb68209a92f35f7` |
| v3.3.0 | Arc | `0xE8113a9a9CddD6d13fe8A3E32eAA687e108C4616` | [BuybackAndBurnRecipient](#buybackandburnrecipient): 100% native ETH, 100% token | `214b8a69bc76f78766ff7d71ceb68209a92f35f7` |

#### UERC20BeneficiaryVault

Deployed to a different address on each chain. Distributes and attributes creator fees.

| Version | Chain | Address | Commit Hash |
| --- | --- | --- | --- |
| v3.3.0 | Robinhood Chain | `0x26d2F7AcB07707034406a0dC458351Bb63C02553` | `7ea523c9d75a51cb2f497be5e49bacdaeb80a342` |
| v3.3.0 | Arc | `0x3892aB3Dcf62785Ee3077ea008486c3a6bCf51Af` | `1eda9f0c0243e2fdc0cbe0d665200ffa8c2ba53a` |

#### CompoundingClaimRecipient

Deployed to a different address on each chain. Permissionlessly compounds LP fees into liquidity.

| Version | Chain | Address | Commit Hash |
| --- | --- | --- | --- |
| v3.3.0 | Robinhood Chain | `0xf585b5D728A8fdE743027307BF5F3556E3B9C58D` | `7ea523c9d75a51cb2f497be5e49bacdaeb80a342` |

#### BuybackAndBurnRecipient

Deployed to a different address based on parameters. Releases funds in exchange for burning a fixed token amount.

| Version | Chain | Parameters | Address | Commit Hash |
| --- | --- | --- | --- | --- |
| v3.3.0 | Arc | minCurrency1Amount: `500_000e18` | `0x5cEe9852d136833aE26c9E36a96fC02Cdfc9C40C` | `214b8a69bc76f78766ff7d71ceb68209a92f35f7` |
| v3.2.0 | Robinhood Chain | minCurrency1Amount: `500_000e18` | `0xa1ba4CC12654D2b188e3ba77dc86c75cA47f1A4e` | `0b5ee0527af94a8c635b6af5b334a7d17c5ed719` |

#### VestingClaimRecipient

Deployed to a different based on parameters. Claims and distributes tokens over time.

| Version | Chain | Parameters | Address | Commit Hash |
| --- | --- | --- | --- | --- |
| v3.2.0 | Robinhood Chain | maxCurrency0PerBlock: `125000000000000`, maxCurrency1PerBlock: `50000000000000000000000`, recipient: [BuybackAndBurnRecipient](#buybackandburnrecipient) | `0xeF451B293ED8C61d20f7d13ef336a496F0cc2c26` | `0b5ee0527af94a8c635b6af5b334a7d17c5ed719` |
| v3.3.0 | Arc | maxCurrency0PerBlock: `250000`, maxCurrency1PerBlock: `50000000000000000000000`, recipient: [BuybackAndBurnRecipient](#buybackandburnrecipient) | `0xf914C6b46b47aF733390C6cBC77Ad48D146Eb891` | `0b5ee0527af94a8c635b6af5b334a7d17c5ed719` |

#### InitializerHook

Restricts pool initialization to a deployed LBPStrategy instance.

| Version | Chain | Address | LBPStrategy | Salt | Commit Hash |
| --- | --- | --- | --- | --- | --- |
| v3.3.0 | Mainnet | `0xcDf73dEddE5e8C2FdC9c01C18607e0B40380E000` | [`0x2EEF0e2a9a652d755AccAD95a24541A98B5CA000`](#lbpstrategy) | `0x00000000000000000000000000000000000000000000000000000000000010a4` | `7ea523c9d75a51cb2f497be5e49bacdaeb80a342` |
| v3.3.0 | Unichain | `0xF44Ba9c854Ec0ad6a899864bdfF560AAD4002000` | [`0x48F55E7E8ac229aA4e2f3F2d44aa9284D86da000`](#lbpstrategy) | `0x0000000000000000000000000000000000000000000000000000000000001046` | `7ea523c9d75a51cb2f497be5e49bacdaeb80a342` |
| v3.3.0 | Robinhood Chain | `0x5fB5229FBA341dFE5a7e6A14d4809D6Cf887a000` | [`0xbf1aB81f7d534b2CC0Da76fcf4d541322bB0e000`](#lbpstrategy) | `0x000000000000000000000000000000000000000000000000000000000000247f` | `7ea523c9d75a51cb2f497be5e49bacdaeb80a342` |
| v3.3.0 | Avalanche | `0x602bd3e53b5e80f732b0859E90564CFCAcb52000` | [`0x7575c9488AB7913e7749B9F5e02789355699E000`](#lbpstrategy) | `0x0000000000000000000000000000000000000000000000000000000000000d67` | `7ea523c9d75a51cb2f497be5e49bacdaeb80a342` |
| v3.3.0 | XLayer | `0xcaf0443A5F171DC1dd5574eE50dD2c45274da000` | [`0xde758D7B3202b7f4f842E8313Fc04Bf19c6Be000`](#lbpstrategy) | `0x000000000000000000000000000000000000000000000000000000000000df03` | `7ea523c9d75a51cb2f497be5e49bacdaeb80a342` |
| v3.3.0 | Ink | `0x47AFDD2D8591275E9dF688FCacb8Cf5C772Ee000` | [`0x0cB98d78be96D5119E49664a9F24fDA22f83E000`](#lbpstrategy) | `0x000000000000000000000000000000000000000000000000000000000000ae2a` | `7ea523c9d75a51cb2f497be5e49bacdaeb80a342` |
| v3.3.0 | Arc | `0x0A2Bf52DA5D72fd1B1cDB21ABd4Bd8672b512000` | [`0x542BCDA1015485ef0B1cD11B835DC58DF5102000`](#lbpstrategy) | `0x000000000000000000000000000000000000000000000000000000000000403b` | `7ea523c9d75a51cb2f497be5e49bacdaeb80a342` |
| v3.3.0 | Sepolia | `0x1600059B95A80d500fC42400ea9a88A9C29D2000` | [`0x95434E898Af471945Cab33D5064d2aC1A6Ba2000`](#lbpstrategy) | `0x0000000000000000000000000000000000000000000000000000000000000edf` | `7ea523c9d75a51cb2f497be5e49bacdaeb80a342` |
| v3.3.0 | Base Sepolia | `0xE09e0D23097B08443C09F2AE23e7201601422000` | [`0x73ad52384798AdADfBe19fCfD28ff09D2CC82000`](#lbpstrategy) | `0x0000000000000000000000000000000000000000000000000000000000011e77` | `7ea523c9d75a51cb2f497be5e49bacdaeb80a342` |

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
