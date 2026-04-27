# IDistributionStrategy
[Git Source](https://github.com/Uniswap/token-launcher/blob/49827f7454f22af093d9c28dd4f43a04f86b3b5c/src/interfaces/IDistributionStrategy.sol)

**Title:**
IDistributionStrategy

Interface for token distribution strategies.


## Functions
### initializeDistribution

Initialize a distribution of tokens under this strategy.

Contracts can choose to deploy an instance with a factory-model or handle all distributions within the
implementing contract. For some strategies this function will handle the entire distribution, for others it
could merely set up initial state and provide additional entrypoints to handle the distribution logic.


```solidity
function initializeDistribution(address token, uint256 totalSupply, bytes calldata configData, bytes32 salt)
    external
    returns (IDistributionContract distributionContract);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`token`|`address`|The token that is being distributed.|
|`totalSupply`|`uint256`|The supply of the token that is being distributed.|
|`configData`|`bytes`|Arbitrary, strategy-specific parameters.|
|`salt`|`bytes32`|The optional salt for deterministic deployment.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`distributionContract`|`IDistributionContract`|The contract that will handle or manage the distribution. (Could be `address(this)` if the strategy is handled in-place, or a newly deployed instance).|


## Events
### DistributionInitialized
Emitted when a distribution is initialized


```solidity
event DistributionInitialized(address indexed distributionContract, address indexed token, uint256 totalSupply);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`distributionContract`|`address`|The contract that was created that will handle or manage the distribution.|
|`token`|`address`|The token that is being distributed.|
|`totalSupply`|`uint256`|The supply of the token that is being distributed.|

## Errors
### InvalidAmount
Error thrown when the amount to be distributed is invalid


```solidity
error InvalidAmount(uint256 amount, uint256 maxAmount);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`amount`|`uint256`|The invalid amount|
|`maxAmount`|`uint256`|The maximum valid amount to be distributed|

