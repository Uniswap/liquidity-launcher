# TokenDistribution
[Git Source](https://github.com/Uniswap/token-launcher/blob/49827f7454f22af093d9c28dd4f43a04f86b3b5c/src/libraries/TokenDistribution.sol)

**Title:**
TokenDistribution

Library for calculating token distribution splits between auction and reserves

Handles the splitting of total token supply based on percentage allocations


## State Variables
### MAX_TOKEN_SPLIT
Maximum value for token split percentage (100% in basis points)

1e7 = 10,000,000 basis points = 100%


```solidity
uint24 public constant MAX_TOKEN_SPLIT = 1e7
```


## Functions
### calculateTokenSplit

Calculates the token split based on the split ratio


```solidity
function calculateTokenSplit(uint128 _totalSupply, uint24 _splitMps) internal pure returns (uint128);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_totalSupply`|`uint128`|The total token supply|
|`_splitMps`|`uint24`|The percentage to split (in basis points, max 1e7)|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint128`|the split amount of tokens|


### calculateReserveSupply

Calculates the reserve supply (remainder after auction allocation)


```solidity
function calculateReserveSupply(uint128 _totalSupply, uint24 _splitMps) internal pure returns (uint128);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_totalSupply`|`uint128`|The total token supply|
|`_splitMps`|`uint24`|The percentage to split (in basis points, max 1e7)|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint128`|the amount of tokens reserved for liquidity|


