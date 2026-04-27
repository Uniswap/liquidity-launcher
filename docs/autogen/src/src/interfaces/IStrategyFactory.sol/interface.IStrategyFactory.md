# IStrategyFactory
[Git Source](https://github.com/Uniswap/token-launcher/blob/49827f7454f22af093d9c28dd4f43a04f86b3b5c/src/interfaces/IStrategyFactory.sol)

**Inherits:**
[IDistributionStrategy](/src/interfaces/IDistributionStrategy.sol/interface.IDistributionStrategy.md)

**Title:**
IStrategyFactory

Interface for strategy factories


## Functions
### getAddress

Precomputes the address of the deployed strategy contract via Create2

The returned address is not guaranteed to be a correct deployable address due to
construction time validity checks and hook address validation.

The `sender` should be the same as the one used to initialize the distribution


```solidity
function getAddress(address token, uint256 amount, bytes calldata configData, bytes32 salt, address sender)
    external
    view
    returns (address);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`token`|`address`|The address of the token to be distributed|
|`amount`|`uint256`|The amount of tokens intended for distribution|
|`configData`|`bytes`|The configuration data for the strategy|
|`salt`|`bytes32`|The salt to use for the deterministic deployment|
|`sender`|`address`|The sender of the initializeDistribution transaction|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`address`|The address of the deployed strategy contract|


