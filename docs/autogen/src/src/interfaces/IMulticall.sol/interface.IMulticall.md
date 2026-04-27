# IMulticall
[Git Source](https://github.com/Uniswap/token-launcher/blob/49827f7454f22af093d9c28dd4f43a04f86b3b5c/src/interfaces/IMulticall.sol)

**Title:**
IMulticall

Interface for the Multicall contract


## Functions
### multicall

Call multiple functions in the current contract and return the data from all of them if they all succeed


```solidity
function multicall(bytes[] calldata data) external returns (bytes[] memory results);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`data`|`bytes[]`|The encoded function data for each of the calls to make to this contract|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`results`|`bytes[]`|The results from each of the calls passed in via data|


