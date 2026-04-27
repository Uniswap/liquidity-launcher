# TickCalculations
[Git Source](https://github.com/Uniswap/token-launcher/blob/49827f7454f22af093d9c28dd4f43a04f86b3b5c/src/libraries/TickCalculations.sol)

**Title:**
TickCalculations

Library for tick calculations


## Functions
### tickSpacingToMaxLiquidityPerTick

Derives max liquidity per tick from given tick spacing

Taken directly from Pool.sol


```solidity
function tickSpacingToMaxLiquidityPerTick(int24 tickSpacing) internal pure returns (uint128 result);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`tickSpacing`|`int24`|The amount of required tick separation, realized in multiples of `tickSpacing` (cannot be 0) e.g., a tickSpacing of 3 requires ticks to be initialized every 3rd tick i.e., ..., -6, -3, 0, 3, 6, ...|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`result`|`uint128`|The max liquidity per tick|


### tickFloor

Rounds down to the nearest tick spacing if needed


```solidity
function tickFloor(int24 tick, int24 tickSpacing) internal pure returns (int24);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`tick`|`int24`|The tick to round down|
|`tickSpacing`|`int24`|The tick spacing to round down to (cannot be 0)|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`int24`|The rounded down tick|


### tickStrictCeil

Rounds up to the next tick spacing


```solidity
function tickStrictCeil(int24 tick, int24 tickSpacing) internal pure returns (int24);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`tick`|`int24`|The tick to round up|
|`tickSpacing`|`int24`|The tick spacing to round up to (cannot be 0)|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`int24`|The rounded up tick|


