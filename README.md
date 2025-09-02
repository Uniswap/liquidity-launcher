# Token Launcher

A comprehensive token launch system built on Uniswap V4 that facilitates token creation, distribution, and liquidity bootstrapping. The system allows users to create new tokens and distribute them through various strategies, with the primary implementation being a Liquidity Bootstrapping Pool (LBP) that combines price discovery via auction with automated liquidity provisioning.

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

# Build the project
forge build

# Run tests
forge test

# Run tests with gas reporting
forge test --gas-report

# Run with higher fuzz runs (CI mode)
forge test --profile ci
```

The project requires the following environment variable for testing:
- `FORK_URL`: An Ethereum mainnet RPC endpoint for fork testing

## Core Components

### TokenLauncher

The main entry point contract that orchestrates token creation and distribution. It provides two primary functions:

`createToken` deploys a new token through a specified factory contract. The launcher supports different token standards including basic ERC20 tokens (UERC20) and super tokens (USUPERC20) that can be deployed deterministically across multiple chains. Tokens are created with metadata support including description, website, and image URIs.

`distributeToken` transfers tokens to a distribution strategy which handles the actual distribution logic. The system uses Permit2 for efficient token transfers, allowing users to approve once and execute multiple transactions without additional approvals.

The launcher includes multicall functionality, enabling multiple operations to be batched in a single transaction for gas efficiency.

### Token Factories

The system includes two token factory implementations:

**UERC20Factory** creates standard ERC20 tokens with extended metadata. These tokens support Permit2 by default and include on-chain metadata storage. The factory uses CREATE2 for deterministic addresses based on token parameters.

**USUPERC20Factory** extends the basic factory with multi-chain capabilities. Tokens deployed through this factory can be created on multiple chains with the same address, though only the home chain holds the initial supply. This enables seamless cross-chain token deployment while maintaining consistency across networks.

### Distribution Strategies

The distribution system is modular, allowing different strategies to be implemented. The main implementation is:

**LBPStrategyBasic** implements a Liquidity Bootstrapping Pool strategy that splits the token supply between a price discovery auction and liquidity reserves. The auction determines the initial price, which is then used to bootstrap a Uniswap V4 pool. After the auction completes, the contract migrates the liquidity to V4, creating both a full-range position and potentially a one-sided position for optimal capital efficiency.

The strategy validates parameters to ensure reasonable configurations, such as limiting the auction allocation to 50% of total supply and checking tick spacing and fee tier validity.

### Supporting Infrastructure

**Permit2Forwarder** handles token approvals through the Permit2 protocol, providing a unified approval interface that reduces the number of transactions users need to sign.

**HookBasic** provides Uniswap V4 hook functionality, allowing the LBP strategy to act as a hook for the pools it creates, enabling custom pool behavior if needed.

**Multicall** enables batching multiple function calls, useful for complex operations like creating and distributing tokens in a single transaction.

## Contract Interactions

The typical flow for launching a token involves several steps:

1. A user calls `TokenLauncher.createToken()` specifying the factory, token parameters, and metadata. The token is minted to the launcher contract.

2. The user then calls `TokenLauncher.distributeToken()` with a distribution configuration. For the LBP strategy, this includes:
   - The split between auction and liquidity reserves
   - Pool parameters (fee tier, tick spacing)
   - Auction parameters (duration, pricing steps)
   - The recipient for the LP position

3. The distribution strategy deploys an auction contract and transfers the allocated tokens. The auction runs according to the specified parameters.

4. Once the auction completes, it notifies the LBP strategy with the final price and raised funds. The strategy validates these parameters and stores them for migration.

5. After a configurable delay (migrationBlock), anyone can call `migrate()` to initialize the Uniswap V4 pool and deploy the liquidity. The contract creates:
   - A full-range position with the raised funds and corresponding tokens
   - Potentially an additional one-sided position with remaining tokens if any

## Key Interfaces

**ITokenLauncher** defines the main launcher interface for creating and distributing tokens.

**IDistributionContract** implemented by contracts that receive and distribute tokens. The `onTokensReceived()` callback ensures contracts are notified when they receive tokens.

**IDistributionStrategy** implemented by factory contracts that deploy distribution contracts. The `initializeDistribution()` function creates new distribution instances.

**ISubscriber** implemented by contracts that need to be notified of events, particularly used for price discovery notification from the auction to the LBP strategy.

**ITokenFactory** defines the interface for token creation factories, standardizing how different token types are deployed.

## Testing

The test suite covers various aspects of the system:

- Token creation with different factories and parameters
- Distribution strategy deployment and configuration
- Auction mechanics and price discovery
- Migration to Uniswap V4 pools
- Edge cases and parameter validation
- Gas optimization benchmarks

Tests use mainnet forking to interact with real Uniswap V4 contracts. The default test configuration uses minimal fuzz runs for speed, while CI uses extensive fuzzing for thorough testing.

Key test files include:
- `TokenLauncher.t.sol` - Core launcher functionality
- `LBPStrategyBasic.*.t.sol` - LBP strategy test suite
- `UERC20*.t.sol` - Token factory tests
- `Permit2Forwarder.t.sol` - Permit2 integration tests

## Security Considerations

The system implements several security measures:

- Parameter validation to prevent unreasonable configurations
- Reentrancy protection through checks-effects-interactions pattern
- Use of established protocols (Permit2, Uniswap V4) for critical operations
- Deterministic deployment addresses preventing frontrunning
- Migration delays allowing time for review before liquidity deployment

The LBP strategy ensures at least 50% of tokens remain for liquidity, preventing scenarios where all tokens go to auction. Price bounds are validated to stay within Uniswap V4's supported range, and liquidity calculations check against per-tick limits.

## Dependencies

The project relies on several external libraries:
- Uniswap V4 Core and Periphery for pool and position management
- OpenZeppelin for standard implementations and utilities
- Solady for gas-optimized ERC20 implementation
- Permit2 for token approval handling
- TWAP Auction for price discovery mechanism
- Forge Standard Library for testing