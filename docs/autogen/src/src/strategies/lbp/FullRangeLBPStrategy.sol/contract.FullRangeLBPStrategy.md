# FullRangeLBPStrategy
[Git Source](https://github.com/Uniswap/token-launcher/blob/49827f7454f22af093d9c28dd4f43a04f86b3b5c/src/strategies/lbp/FullRangeLBPStrategy.sol)

**Inherits:**
[LBPStrategyBase](/src/strategies/lbp/LBPStrategyBase.sol/abstract.LBPStrategyBase.md)

**Title:**
FullRangeLBPStrategy

Strategy to initialize a Uniswap v4 pool and migrate the tokens and raised funds into a full range position

**Note:**
security-contact: security@uniswap.org


## Functions
### constructor


```solidity
constructor(
    address _token,
    uint128 _totalSupply,
    MigratorParameters memory _migratorParams,
    bytes memory _initializerParams,
    IPositionManager _positionManager,
    IPoolManager _poolManager
) LBPStrategyBase(_token, _totalSupply, _migratorParams, _initializerParams, _positionManager, _poolManager);
```

### _createPositionPlan

Creates the position plan based on migration data


```solidity
function _createPositionPlan(MigrationData memory _data) internal view override returns (bytes memory);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_data`|`MigrationData`|Migration data with all necessary parameters|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`bytes`|plan The encoded position plan|


### _getTokenTransferAmount

Calculates the amount of tokens to transfer


```solidity
function _getTokenTransferAmount(MigrationData memory _data) internal pure override returns (uint128);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_data`|`MigrationData`|Migration data|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint128`|The amount of tokens to transfer to the position manager|


### _getCurrencyTransferAmount

Calculates the amount of currency to transfer


```solidity
function _getCurrencyTransferAmount(MigrationData memory _data) internal pure override returns (uint128);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_data`|`MigrationData`|Migration data|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint128`|The amount of currency to transfer to the position manager|


