# FullRangeLBPStrategyFactory
[Git Source](https://github.com/Uniswap/token-launcher/blob/49827f7454f22af093d9c28dd4f43a04f86b3b5c/src/factories/lbp/FullRangeLBPStrategyFactory.sol)

**Inherits:**
[StrategyFactory](/src/factories/StrategyFactory.sol/abstract.StrategyFactory.md)

**Title:**
FullRangeLBPStrategyFactory

Factory for the FullRangeLBPStrategy contract

**Note:**
security-contact: security@uniswap.org


## State Variables
### positionManager
The position manager that will be used to create the position


```solidity
IPositionManager public immutable positionManager
```


### poolManager
The pool manager that will be used to create the pool


```solidity
IPoolManager public immutable poolManager
```


## Functions
### constructor


```solidity
constructor(IPositionManager _positionManager, IPoolManager _poolManager) ;
```

### _validateParamsAndReturnDeployedBytecode

Overridable function to validate the deployment params and return the deployed bytecode for the strategy

Reverts if the total supply is greater than uint128.max


```solidity
function _validateParamsAndReturnDeployedBytecode(address token, uint256 totalSupply, bytes calldata configData)
    internal
    view
    override
    returns (bytes memory deployedBytecode);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`token`|`address`|The address of the token to be distributed|
|`totalSupply`|`uint256`|The total supply of the token to be distributed|
|`configData`|`bytes`|The configData used to initialize the strategy|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`deployedBytecode`|`bytes`|The deployed bytecode for the strategy|


