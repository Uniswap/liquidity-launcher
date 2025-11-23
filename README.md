# Liquidity Launcher

## Overview

Liquidity Launcher is a comprehensive launch system built on Uniswap V4 that facilitates token creation, distribution, and liquidity bootstrapping. The system provides a streamlined approach for projects to:

- **Create** new ERC20 tokens with extended metadata and cross-chain capabilities
- **Distribute** tokens through customizable strategies
- **Bootstrap** liquidity using price discovery mechanisms
- **Deploy** automated market making pools on Uniswap V4

The primary distribution strategy is a Liquidity Bootstrapping Pool (LBP) that combines a price discovery auction with automated liquidity provisioning with immediate trading liquidity.

## Important Safety Notes

⚠️ **Rebasing Tokens and Fee-on-Transfer Tokens are NOT compatible with LiquidityLauncher.** The system is designed for standard ERC20 tokens and will not function correctly with tokens that have dynamic balances or transfer fees.

⚠️ **Always use multicall for atomic token creation and distribution.** When creating and distributing tokens, batch both operations in a single transaction with `payerIsUser = false` to prevent tokens from sitting unprotected in the LiquidityLauncher contract where anyone could call `distribute()`.

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

## Deployment Addresses

### Liquidity Launcher

| Network | Address | Commit Hash | Version |
|---------|---------|------------|---------|
| Mainnet | 0x00000008412db3394C91A5CbD01635c6d140637C | fd5be9b7a918ca3d925d985dff9bcde82b3b8a9d | v1.0.0-candidate |
| Unichain | 0x00000008412db3394C91A5CbD01635c6d140637C | fd5be9b7a918ca3d925d985dff9bcde82b3b8a9d | v1.0.0-candidate |
| Base | 0x00000008412db3394C91A5CbD01635c6d140637C | fd5be9b7a918ca3d925d985dff9bcde82b3b8a9d | v1.0.0-candidate |
| Sepolia | 0x00000008412db3394C91A5CbD01635c6d140637C | fd5be9b7a918ca3d925d985dff9bcde82b3b8a9d | v1.0.0-candidate |

### LBPStrategyBasicFactory

| Network | Address | Commit Hash | Version |
|---------|---------|------------|---------|
| Mainnet | 0xbbbb6FFaBCCb1EaFD4F0baeD6764d8aA973316B6 | fd5be9b7a918ca3d925d985dff9bcde82b3b8a9d | v1.0.0-candidate |
| Base | 0xC46143aE2801b21B8C08A753f9F6b52bEaD9C134 | fd5be9b7a918ca3d925d985dff9bcde82b3b8a9d | v1.0.0-candidate |
| Unichain | 0x435DDCFBb7a6741A5Cc962A95d6915EbBf60AE24 | fd5be9b7a918ca3d925d985dff9bcde82b3b8a9d | v1.0.0-candidate |

### VirtualLBPStrategyFactory

| Network | Address | Commit Hash | Version |
|---------|---------|------------|---------|
| Mainnet | 0x00000010F37b6524617b17e66796058412bbC487 | fd5be9b7a918ca3d925d985dff9bcde82b3b8a9d | v1.0.0-candidate |
| Sepolia | 0xC695ee292c39Be6a10119C70Ed783d067fcecfA4 | fd5be9b7a918ca3d925d985dff9bcde82b3b8a9d | v1.0.0-candidate |

## Audits
- 10/1 [OpenZeppelin](./docs/audit/Uniswap%20Token%20Launcher%20Audit.pdf)
- 10/20 [ABDK Consulting](./docs/audit/ABDK_Uniswap_TokenLauncher_v_1_0.pdf)
- 10/27 [Spearbit](./docs/audit/report-cantinacode-uniswap-token-launcher-1027.pdf)

## Core Components

### LiquidityLauncher

The main entry point contract that orchestrates token creation and distribution. It provides two primary functions:

`createToken` deploys a new token through a specified factory contract. The launcher supports different token standards including basic ERC20 tokens (UERC20) and Superchain tokens (USUPERC20) that can be deployed deterministically. Tokens are created with metadata support including description, website, and image URIs.

`distributeToken` transfers tokens to a distribution strategy which handles the actual distribution logic. The system uses Permit2 for efficient token transfers, allowing users to approve once and execute multiple transactions without additional approvals.

### Token Factories

The system includes two token factory implementations:

**UERC20Factory** creates standard ERC20 tokens with extended metadata. These tokens support Permit2 by default and include on-chain metadata storage. The factory uses CREATE2 for deterministic addresses based on token parameters.

**USUPERC20Factory** extends the basic factory with superchain capabilities. Tokens deployed through this factory can be created on multiple chains with the same address, though only the home chain holds the initial supply. This enables seamless cross-chain token deployment while maintaining consistency across networks.

### Distribution Strategies

The distribution system is modular, allowing different strategies to be implemented. The main implementation is:

**LBPStrategyBasic** implements a Liquidity Bootstrapping Pool strategy that splits the token supply between a price discovery auction and liquidity reserves. The auction determines the initial price, which is then used to bootstrap a Uniswap V4 pool. After the auction completes, the contract migrates the liquidity to V4, creating both a full-range position and potentially a one-sided position for optimal capital efficiency.

The strategy validates parameters to ensure reasonable configurations, such as checking tick spacing and fee tier validity.

## Warnings

Users should be aware that it is trivially easy to create a LBPStrategy and corresponding Auction with malicious parameters. This can lead to a loss of funds or a degraded expereience. You must validate all parameters set on each contract in the system before interacting with them.

Since the LBPStrategyBasic cannot control the final price of the Auction, or how much currency is raised, it is possible to create an Auction such that it is impossible to migrate the liquidity to V4. Users should be aware that malicious deployers can design such parameters to eventually sweep the currency and tokens from the contract.

We strongly recommend that a token with value such as ETH or USDC is used as the `currency`.

### Supporting Infrastructure

**Permit2Forwarder** handles token approvals through the Permit2 protocol, providing a unified approval interface that reduces the number of transactions users need to sign.

**HookBasic** provides Uniswap v4 hook functionality, allowing the LBP strategy to act as a hook for the pools it creates.

## Contract Interactions

### Typical Launch Flow

The typical flow for launching a token involves several coordinated steps:

#### 1. Token Creation and Distribution

- Use multicall to atomically call `LiquidityLauncher.createToken()` and `LiquidityLauncher.distributeToken()`
- Set `payerIsUser = false` since tokens are already in the launcher after creation

For the LBP strategy, the distribution configuration includes:

- **Allocation Split**: Division between auction and liquidity reserves
- **Pool Parameters**: Fee tier and tick spacing for the Uniswap V4 pool
- **Auction Parameters**: Duration, pricing steps, and reserve price
- **LP Recipient**: Address that will receive the liquidity position NFT

#### 2. Auction Phase

The distribution strategy deploys an auction contract and transfers the allocated tokens. The auction runs according to the specified parameters, allowing users to bid for tokens at decreasing prices.

#### 3. Price Discovery Notification

Once the auction completes, it transfers the raised funds to the LBP Strategy and the strategy
grabs the final clearing price.

#### 4. Migration to Uniswap V4

After a configurable delay (`migrationBlock`), anyone can call `migrate()` to:

- Validate a v4 pool can be created
- Initialize the Uniswap V4 pool at the discovered price
- Deploy liquidity as a full-range position
- Create an optional one-sided position
- Transfer the LP NFT to the designated recipient

**Note:** To optimize gas costs, any minimal dust amounts are foregone and locked in the PoolManager rather than being swept at the end of the migration process.

## Key Interfaces

**ILiquidityLauncher** defines the main launcher interface for creating and distributing tokens.

**IDistributionContract** implemented by contracts that receive and distribute tokens. The `onTokensReceived()` callback ensures contracts are notified when they receive tokens.

**IDistributionStrategy** implemented by factory contracts that deploy distribution contracts. The `initializeDistribution()` function creates new distribution instances.

**ITokenFactory** defines the interface for token creation factories, standardizing how different token types are deployed.
