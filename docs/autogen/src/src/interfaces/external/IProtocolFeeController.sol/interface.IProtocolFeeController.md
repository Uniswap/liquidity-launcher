# IProtocolFeeController
[Git Source](https://github.com/Uniswap/token-launcher/blob/49827f7454f22af093d9c28dd4f43a04f86b3b5c/src/interfaces/external/IProtocolFeeController.sol)

**Title:**
IProtocolFeeController


## Functions
### getProtocolFeeBps

Returns the protocol fee in basis points, must be less than or equal to the configured
maximum protocol fee of 100 basis points.


```solidity
function getProtocolFeeBps(address currency, uint256 amount) external view returns (uint24);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`currency`|`address`|The currency address, address(0) for native|
|`amount`|`uint256`|The amount denoted in currency|


