# LBPStrategyBase
[Git Source](https://github.com/Uniswap/token-launcher/blob/49827f7454f22af093d9c28dd4f43a04f86b3b5c/src/strategies/lbp/LBPStrategyBase.sol)

**Inherits:**
[ILBPStrategyBase](/src/interfaces/ILBPStrategyBase.sol/interface.ILBPStrategyBase.md), [SelfInitializerHook](/src/periphery/hooks/SelfInitializerHook.sol/abstract.SelfInitializerHook.md), BlockNumberish

**Title:**
LBPStrategyBase

Base contract for derived LBPStrategies

**Note:**
security-contact: security@uniswap.org


## State Variables
### token
The token that is being distributed


```solidity
address public immutable token
```


### currency
The currency that the initializer raised funds in


```solidity
address public immutable currency
```


### poolLPFee
The LP fee that the v4 pool will use expressed in hundredths of a bip (1e6 = 100%)


```solidity
uint24 public immutable poolLPFee
```


### poolTickSpacing
The tick spacing that the v4 pool will use


```solidity
int24 public immutable poolTickSpacing
```


### totalSupply
The supply of the token that was sent to this contract to be distributed


```solidity
uint128 public immutable totalSupply
```


### reserveTokenAmount
The remaining supply of the token that was not sent to the auction


```solidity
uint128 public immutable reserveTokenAmount
```


### maxCurrencyAmountForLP
The maximum amount of currency that can be used to mint the initial liquidity position in the v4 pool


```solidity
uint128 public immutable maxCurrencyAmountForLP
```


### positionRecipient
The address that will receive the position


```solidity
address public immutable positionRecipient
```


### migrationBlock
The block number at which migration is allowed


```solidity
uint64 public immutable migrationBlock
```


### initializerFactory
The initializer factory


```solidity
address public immutable initializerFactory
```


### operator
The operator that can sweep currency and tokens from the pool after sweepBlock


```solidity
address public immutable operator
```


### sweepBlock
The block number at which the operator can sweep currency and tokens from the pool


```solidity
uint64 public immutable sweepBlock
```


### positionManager
The position manager that will be used to create the position


```solidity
IPositionManager public immutable positionManager
```


### initializer
The initializer of the pool


```solidity
ILBPInitializer public initializer
```


### initializerParameters
The initializer parameters used to initialize the initializer via the factory


```solidity
bytes public initializerParameters
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
    IPoolManager _poolManager
) SelfInitializerHook(_poolManager);
```

### _getPoolToken

Gets the address of the token that will be used to create the pool


```solidity
function _getPoolToken() internal view virtual returns (address);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`address`|The address of the token that will be used to create the pool|


### onTokensReceived

Notify a distribution contract that it has received the tokens to distribute


```solidity
function onTokensReceived() external;
```

### migrate

Migrates the raised funds and tokens to a v4 pool


```solidity
function migrate() external;
```

### sweepToken

Allows the operator to sweep tokens from the contract

Can only be called after sweepBlock by the operator


```solidity
function sweepToken() external;
```

### sweepCurrency

Allows the operator to sweep currency from the contract

Can only be called after sweepBlock by the operator


```solidity
function sweepCurrency() external;
```

### _currency0

Get the currency0 of the pool


```solidity
function _currency0() internal view returns (Currency);
```

### _currency1

Get the currency1 of the pool


```solidity
function _currency1() internal view returns (Currency);
```

### _currencyIsCurrency0

Returns true if the currency is currency0 of the pool


```solidity
function _currencyIsCurrency0() internal view returns (bool);
```

### _validateMigratorParams

Validates the migrator parameters and reverts if any are invalid. Continues if all are valid


```solidity
function _validateMigratorParams(uint128 _totalSupply, MigratorParameters memory _migratorParams) internal pure;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_totalSupply`|`uint128`|The total supply of the token that was sent to this contract to be distributed|
|`_migratorParams`|`MigratorParameters`|The migrator parameters that will be used to create the v4 pool and position|


### _validateInitializerParams

Validates that the deployed initializer parameters are valid for this strategy implementation

MUST be called in the same transaction as the deployment of the initializer


```solidity
function _validateInitializerParams(ILBPInitializer _initializer) internal view virtual;
```

### _validateMigration

Validates migration timing and currency balance


```solidity
function _validateMigration(LBPInitializationParams memory _lbpParams) internal view;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_lbpParams`|`LBPInitializationParams`|The LBP initialization parameters|


### _prepareMigrationData

Prepares all migration data including prices, amounts, and liquidity calculations


```solidity
function _prepareMigrationData(LBPInitializationParams memory _lbpParams)
    internal
    view
    returns (MigrationData memory);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_lbpParams`|`LBPInitializationParams`|The LBP initialization parameters|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`MigrationData`|data MigrationData struct containing all calculated values|


### _initializePool

Initializes the pool with the calculated price


```solidity
function _initializePool(MigrationData memory _data) internal returns (PoolKey memory key);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_data`|`MigrationData`|Migration data containing the sqrt price|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`key`|`PoolKey`|The pool key for the initialized pool|


### _transferAssetsAndExecutePlan

Transfers assets to position manager and executes the position plan


```solidity
function _transferAssetsAndExecutePlan(
    uint128 _tokenTransferAmount,
    uint128 _currencyTransferAmount,
    bytes memory _plan
) internal;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_tokenTransferAmount`|`uint128`|The amount of tokens to transfer to the position manager|
|`_currencyTransferAmount`|`uint128`|The amount of currency to transfer to the position manager|
|`_plan`|`bytes`|The encoded position plan to execute|


### _basePositionParams

Creates the base position parameters


```solidity
function _basePositionParams(MigrationData memory _data) internal view virtual returns (BasePositionParams memory);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_data`|`MigrationData`|Migration data with all necessary parameters|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`BasePositionParams`|baseParams The base position parameters|


### _createPositionPlan

Creates the position plan based on migration data


```solidity
function _createPositionPlan(MigrationData memory _data) internal virtual returns (bytes memory plan);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_data`|`MigrationData`|Migration data with all necessary parameters|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`plan`|`bytes`|The encoded position plan|


### _getTokenTransferAmount

Calculates the amount of tokens to transfer


```solidity
function _getTokenTransferAmount(MigrationData memory _data) internal view virtual returns (uint128);
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
function _getCurrencyTransferAmount(MigrationData memory _data) internal view virtual returns (uint128);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_data`|`MigrationData`|Migration data|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint128`|The amount of currency to transfer to the position manager|


### receive

Receives native currency


```solidity
receive() external payable;
```

