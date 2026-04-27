# ParamsBuilder
[Git Source](https://github.com/Uniswap/token-launcher/blob/49827f7454f22af093d9c28dd4f43a04f86b3b5c/src/libraries/ParamsBuilder.sol)

**Title:**
ParamsBuilder

Library for building position parameters


## State Variables
### ZERO_BYTES
Empty bytes used as hook data when minting positions since no hook data is needed


```solidity
bytes constant ZERO_BYTES = new bytes(0)
```


## Functions
### init

Initializes the parameters, allocating memory for maximum number of params


```solidity
function init() internal pure returns (bytes[] memory params);
```

### addFullRangeParams

Builds the parameters needed to mint a full range position using the position manager


```solidity
function addFullRangeParams(
    bytes[] memory params,
    FullRangeParams memory fullRangeParams,
    PoolKey memory poolKey,
    TickBounds memory bounds,
    bool currencyIsCurrency0,
    address positionRecipient,
    uint128 liquidity
) internal pure returns (bytes[] memory);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`params`|`bytes[]`|The parameters array to populate|
|`fullRangeParams`|`FullRangeParams`|The amounts of currency and token that will be used to mint the position|
|`poolKey`|`PoolKey`|The pool key|
|`bounds`|`TickBounds`|The tick bounds for the full range position|
|`currencyIsCurrency0`|`bool`|Whether the currency address is less than the token address|
|`positionRecipient`|`address`|The recipient of the position|
|`liquidity`|`uint128`||

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`bytes[]`|params The parameters needed to mint a full range position using the position manager|


### addOneSidedParams

Builds the parameters needed to mint a one-sided position using the position manager


```solidity
function addOneSidedParams(
    bytes[] memory params,
    OneSidedParams memory oneSidedParams,
    PoolKey memory poolKey,
    TickBounds memory bounds,
    bool currencyIsCurrency0,
    address positionRecipient,
    uint128 liquidity
) internal pure returns (bytes[] memory);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`params`|`bytes[]`|The parameters array to populate|
|`oneSidedParams`|`OneSidedParams`|The data specific to creating the one-sided position|
|`poolKey`|`PoolKey`|The pool key|
|`bounds`|`TickBounds`|The tick bounds for the one-sided position|
|`currencyIsCurrency0`|`bool`|Whether the currency address is less than the token address|
|`positionRecipient`|`address`|The recipient of the position|
|`liquidity`|`uint128`||

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`bytes[]`|params The parameters needed to mint a one-sided position using the position manager|


### addTakePairParams

Builds the parameters needed to take the pair using the position manager


```solidity
function addTakePairParams(bytes[] memory params, address currency0, address currency1)
    internal
    view
    returns (bytes[] memory);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`params`|`bytes[]`|The parameters array to populate|
|`currency0`|`address`|The currency0 address|
|`currency1`|`address`|The currency1 address|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`bytes[]`|params The parameters needed to take the pair using the position manager|


