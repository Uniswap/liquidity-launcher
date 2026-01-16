# Deployment Guide

## Table of Contents
- [Deployment Process](#deployment-process)
- [Deployment Requirements](#deployment-requirements)
- [Creating a new token](#creating-a-new-token)
- [Token distribution](#token-distribution)
- [Example](#example)
- [Contract verification](#contract-verification)

## Deployment Process
Most deployments will be initiated through the `LiquidityLauncher` contract. If you are also creating a new token, see [Creating a new token](#creating-a-new-token).

## Deployment Requirements

This protocol requires deployment on networks that support the Cancun upgrade, specifically:
- **EIP-1153 (Transient Storage)**: Used by `ReentrancyGuardTransient` for gas-efficient temporary storage

Supported networks include Ethereum mainnet (post-Cancun) and L2s that have implemented the Cancun upgrade. Before deploying on a new network, verify that transient storage opcodes (`TLOAD`/`TSTORE`) are supported.

## Creating a new token
You can create a new token by calling the `createToken` function on the `LiquidityLauncher` contract. This will deploy a new token through a specified factory contract. The launcher supports different token standards including ERC20 tokens (UERC20) and Superchain tokens (USUPERC20).

```solidity
function createToken(
    address factory,
    string calldata name,
    string calldata symbol,
    uint8 decimals,
    uint128 initialSupply,
    address recipient,
    bytes calldata tokenData
) external returns (address tokenAddress);
```

If you are intending to distribute the token via a strategy, you MUST set the `recipient` to the `LiquidityLauncher` contract address. This will ensure that the tokens are distributed via the strategy and not lost. Set it to an address you control in all other cases.

## Token distribution
You can distribute a token by calling the `distributeToken` function on the `LiquidityLauncher` contract. This will transfer the tokens to a distribution strategy which handles the actual distribution logic.

```solidity
struct Distribution {
    address strategy;
    uint256 amount;
    bytes configData;
}

function distributeToken(
    address token,
    Distribution calldata distribution,
    bool payerIsUser,
    bytes32 salt
) external returns (IDistributionContract distributionContract);
```

The `payerIsUser` parameter is a boolean that indicates whether the payer is the user. If the token was created in the same call via `createToken`, set it to `false`. Otherwise, set it to `true` and ensure that the caller has approved the `LiquidityLauncher` contract to spend the token via Permit2.

Depending on the complexity of the distribution strategy, you may need to pass additional parameters to the strategy. These are passed in the `configData` parameter.

Strategies may create any number of additional contracts, but may only return one address to the `LiquidityLauncher` contract. This is the address which will receive the `amount` of tokens specified in the `Distribution` struct.

## Example
```solidity
address liquidityLauncher = vm.envAddress("LIQUIDITY_LAUNCHER");
address uerc20Factory = vm.envAddress("UERC20_FACTORY");
address strategyFactory = vm.envAddress("STRATEGY_FACTORY");
uint128 initialSupply = 1000000000000000000000000;
address alice = makeAddr("ALICE");
// Create a new token
address token = LiquidityLauncher(liquidityLauncher).createToken(
    UERC20Factory(uerc20Factory),
    "Test Token",
    "TEST",
    18,
    initialSupply,
    alice,
    ""
);

vm.prank(alice);
permit2.approve(token, address(liquidityLauncher), type(uint160).max, type(uint48).max);

Distribution memory distribution = Distribution({
    strategy: strategyFactory,
    amount: initialSupply,
    configData: "" // Add any strategy-specific parameters here
});

vm.prank(alice);
//                                                     <alice is the payer>
liquidityLauncher.distributeToken(token, distribution, true, bytes32(0));
```

### Contract verification
Because multiple contracts may be created as part of the initial call to `LiquidityLauncher.distributeToken`, you may need to manually verify the contracts after the deployment.