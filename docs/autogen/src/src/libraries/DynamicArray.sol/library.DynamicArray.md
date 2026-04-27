# DynamicArray
[Git Source](https://github.com/Uniswap/token-launcher/blob/49827f7454f22af093d9c28dd4f43a04f86b3b5c/src/libraries/DynamicArray.sol)

**Title:**
DynamicArray

Library for building dynamic byte arrays. Increase the `MAX_PARAMS_SIZE` to support more parameters.


## State Variables
### MAX_PARAMS_SIZE
The maximum number of parameters that can be stored in the array


```solidity
uint24 constant MAX_PARAMS_SIZE = 6
```


## Functions
### init

Initializes a new array in memory with the maximum size


```solidity
function init() internal pure returns (bytes[] memory params);
```

### append

Appends a new parameter to the array


```solidity
function append(bytes[] memory params, bytes memory param) internal pure returns (bytes[] memory);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`params`|`bytes[]`|The existing array created via `init`|
|`param`|`bytes`|The new parameter to append|


## Errors
### LengthOverflow
Error thrown when the array length overflows the maximum size


```solidity
error LengthOverflow();
```

