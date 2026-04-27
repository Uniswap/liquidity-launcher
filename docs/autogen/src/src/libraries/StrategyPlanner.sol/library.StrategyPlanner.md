# StrategyPlanner
[Git Source](https://github.com/Uniswap/token-launcher/blob/49827f7454f22af093d9c28dd4f43a04f86b3b5c/src/libraries/StrategyPlanner.sol)

**Title:**
StrategyPlanner

Simplified library that orchestrates position planning using helper libraries


## Functions
### init

Initializes empty plan


```solidity
function init() internal pure returns (Plan memory plan);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`plan`|`Plan`|The empty plan|


### encode

Encodes the plan into a bytes array, truncating the parameters array


```solidity
function encode(Plan memory plan) internal pure returns (bytes memory);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`plan`|`Plan`|The plan to encode|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`bytes`|The encoded plan|


### planFullRangePosition

Creates the actions and parameters needed to mint a full range position on the position manager


```solidity
function planFullRangePosition(
    Plan memory plan,
    BasePositionParams memory baseParams,
    FullRangeParams memory fullRangeParams
) internal pure returns (Plan memory);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`plan`|`Plan`|The plan to extend with the new actions and parameters|
|`baseParams`|`BasePositionParams`|The base parameters for the position|
|`fullRangeParams`|`FullRangeParams`|The amounts of currency and token that will be used to mint the position|


### planOneSidedPosition

Creates the actions and parameters needed to mint a one-sided position on the position manager


```solidity
function planOneSidedPosition(
    Plan memory plan,
    BasePositionParams memory baseParams,
    OneSidedParams memory oneSidedParams
) internal pure returns (Plan memory);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`plan`|`Plan`|The plan to extend with the new actions and parameters|
|`baseParams`|`BasePositionParams`|The base parameters for the position|
|`oneSidedParams`|`OneSidedParams`|The amounts of token that will be used to mint the position|


### planTakePair

Plans the final take pair action and parameters


```solidity
function planTakePair(Plan memory plan, BasePositionParams memory baseParams) internal view returns (Plan memory);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`plan`|`Plan`|The plan to extend with the new actions and parameters|
|`baseParams`|`BasePositionParams`|The base parameters for the position|


### getLeftSideBounds

Gets tick bounds for a left-side position (below current tick)


```solidity
function getLeftSideBounds(uint160 initialSqrtPriceX96, int24 poolTickSpacing)
    internal
    pure
    returns (TickBounds memory bounds);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`initialSqrtPriceX96`|`uint160`|The initial sqrt price of the position|
|`poolTickSpacing`|`int24`|The tick spacing of the pool|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`bounds`|`TickBounds`|The tick bounds for the left-side position (returns 0,0 if the current tick is too close to MIN_TICK)|


### getRightSideBounds

Gets tick bounds for a right-side position (above current tick)


```solidity
function getRightSideBounds(uint160 initialSqrtPriceX96, int24 poolTickSpacing)
    internal
    pure
    returns (TickBounds memory bounds);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`initialSqrtPriceX96`|`uint160`|The initial sqrt price of the position|
|`poolTickSpacing`|`int24`|The tick spacing of the pool|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`bounds`|`TickBounds`|The tick bounds for the right-side position (returns 0,0 if the current tick is too close to MAX_TICK)|


