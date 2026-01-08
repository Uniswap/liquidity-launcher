# Technical Reference

## Table of Contents
- [Core Components](#core-components)
    - [LiquidityLauncher](#liquiditylauncher)
    - [Token Factories](#token-factories)
        - [UERC20Factory](#uerc20factory)
        - [USUPERC20Factory](#usuperc20factory)
    - [Distribution Strategies](#distribution-strategies)
        - [FullRangeLBPStrategy](#fullrangelbpstrategy)
        - [AdvancedLBPStrategy](#advancedlbpstrategy)
        - [GovernedLBPStrategy](#governedlbpstrategy)
        - [VirtualLBPStrategy](#virtuallbpstrategy)
    - [Warnings](#warnings)
    - [Periphery contracts](#periphery-contracts)
        - [TimelockedPositionRecipient](#timelockedpositionrecipient)
        - [PositionFeesForwarder](#positionfeesforwarder)
        - [BuybackAndBurnPositionRecipient](#buybackandburnpositionrecipient)
- [Contract Interactions](#contract-interactions)
- [Key Interfaces](#key-interfaces)
- [Important Safety Notes](#important-safety-notes)

## Core Components

### LiquidityLauncher

The main entry point contract that orchestrates token creation and distribution. It provides two primary functions:

`createToken` deploys a new token through a specified factory contract. The launcher supports different token standards including basic ERC20 tokens (UERC20) and Superchain tokens (USUPERC20) that can be deployed deterministically. Tokens are created with metadata support including description, website, and image URIs.

`distributeToken` transfers tokens to a distribution strategy which handles the actual distribution logic. The system uses Permit2 for efficient token transfers, allowing users to approve once and execute multiple transactions without additional approvals.

### Token Factories

The system includes two token factory implementations:

#### UERC20Factory
Creates standard ERC20 tokens with extended metadata. These tokens support Permit2 by default and include on-chain metadata storage. The factory uses CREATE2 for deterministic addresses based on token parameters.

#### USUPERC20Factory
Extends the basic factory with superchain capabilities. Tokens deployed through this factory can be created on multiple chains with the same address, though only the home chain holds the initial supply. This enables seamless cross-chain token deployment while maintaining consistency across networks.

### Distribution Strategies
The distribution system is modular, allowing different strategies to be implemented. The main class of strategies is `LBPStrategy` and its subclasses. At a high level, these contracts are responsible for the creation of a Continuous Clearing Auction, the initialization of a Uniswap V4 pool, and the migration of the liquidity to V4.

They all inherit from the `LBPStrategyBase` contract, which provides the core functionality for the strategy.

#### FullRangeLBPStrategy
A simple implementation that migrates raised funds to Uniswap V4 as a single full-range position. It is the simplest strategy and is suitable for most use cases.

#### AdvancedLBPStrategy
A more advanced strategy that uses any excess tokens or currency after the full-range position is created to seed one-sided positions.

#### GovernedLBPStrategy
A strategy that lets a trusted entity restrict swapping on the liquidity pool.

#### VirtualLBPStrategy
A strategy that implements a virtual token backed by an underlying token. This is useful for tokens with complex vesting or lockup schedules.

All of the above strategies are provided as-is, and custom strategies can be implemented by extending the `LBPStrategyBase` contract.

### Warnings

Users should be aware that it is trivially easy to create a LBPStrategy and corresponding Auction with malicious parameters. This can lead to a loss of funds or a degraded experience. You must validate all parameters set on each contract in the system before interacting with them.

Since LBPStrategies cannot control the final price of the Auction, or how much currency is raised, it is possible to configure an Auction such that it is impossible to migrate the liquidity to V4. Users should be aware that malicious deployers can design such parameters to eventually sweep the currency and tokens from the contract.

We strongly recommend that a token with value such as ETH or USDC is used as the `currency`.

### Periphery contracts
The following periphery contracts are provided as examples.

#### TimelockedPositionRecipient
The `TimelockedPositionRecipient` contract is a utility contract for holding a v4 LP position until a timelock period has passed. It is used to ensure that the position is not transferred to the recipient before the timelock expires.

A deployed instance can be used as the `positionRecipient` when using an LBPStrategy.

#### PositionFeesForwarder
The `PositionFeesForwarder` extends the `TimelockedPositionRecipient` contract and forwards all collected fees to a recipient.

#### BuybackAndBurnPositionRecipient
The `BuybackAndBurnPositionRecipient` extends the `TimelockedPositionRecipient` contract and facilitates burning the collected fees and tokens from the position.

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

## Important Safety Notes

⚠️ **Rebasing Tokens and Fee-on-Transfer Tokens are NOT compatible with LiquidityLauncher.** The system is designed for standard ERC20 tokens and will not function correctly with tokens that have dynamic balances or transfer fees.

⚠️ **Always use multicall for atomic token creation and distribution.** When creating and distributing tokens, batch both operations in a single transaction with `payerIsUser = false` to prevent tokens from sitting unprotected in the LiquidityLauncher contract where anyone could call `distribute()`.