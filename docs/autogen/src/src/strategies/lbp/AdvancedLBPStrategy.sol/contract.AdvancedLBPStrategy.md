# AdvancedLBPStrategy
[Git Source](https://github.com/Uniswap/token-launcher/blob/49827f7454f22af093d9c28dd4f43a04f86b3b5c/src/strategies/lbp/AdvancedLBPStrategy.sol)

**Inherits:**
[LBPStrategyBase](/src/strategies/lbp/LBPStrategyBase.sol/abstract.LBPStrategyBase.md)

**Title:**
AdvancedLBPStrategy

Basic Strategy to distribute tokens and raise funds from an auction to a v4 pool

**Note:**
security-contact: security@uniswap.org


## State Variables
### createOneSidedTokenPosition
Whether to create a one-sided token position. Set on construction.


```solidity
bool public immutable createOneSidedTokenPosition
```


### createOneSidedCurrencyPosition
Whether to create a one-sided currency position. Set on construction.


```solidity
bool public immutable createOneSidedCurrencyPosition
```


## Functions
### constructor


```solidity
constructor(
    address _token,
    uint128 _totalSupply,
    MigratorParameters memory _migratorParams,
    bytes memory _initializerParams,
    IPositionManager _positionManager,
    IPoolManager _poolManager,
    bool _createOneSidedTokenPosition,
    bool _createOneSidedCurrencyPosition
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

Calculates the amount of tokens to transfer to the position manager

In the case where the one sided token position cannot be created, this will transfer too many tokens to POSM
however we will sweep the excess tokens back immediately after creating the positions.


```solidity
function _getTokenTransferAmount(MigrationData memory _data) internal view override returns (uint128);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_data`|`MigrationData`|Migration data|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint128`|The amount of tokens to transfer|


### _getCurrencyTransferAmount

Calculates the amount of currency to transfer to the position manager


```solidity
function _getCurrencyTransferAmount(MigrationData memory _data) internal view override returns (uint128);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_data`|`MigrationData`|Migration data|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint128`|The amount of currency to transfer|


