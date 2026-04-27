# TokenPricing
[Git Source](https://github.com/Uniswap/token-launcher/blob/49827f7454f22af093d9c28dd4f43a04f86b3b5c/src/libraries/TokenPricing.sol)

**Title:**
TokenPricing

Library for pricing operations including price conversions and token amount calculations

Handles conversions between different price representations and calculates swap amounts


## State Variables
### Q192
Q192 format: 192-bit fixed-point number representation

Used for intermediate calculations to maintain precision


```solidity
uint256 public constant Q192 = 1 << 192
```


## Functions
### convertToPriceX192

Converts a Q96 price to Uniswap v4 X192 format in terms of currency1/currency0

Converts price from Q96 to X192 format


```solidity
function convertToPriceX192(uint256 price, bool currencyIsCurrency0) internal pure returns (uint256 priceX192);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`price`|`uint256`|The price in Q96 fixed-point format (96 bits of fractional precision)|
|`currencyIsCurrency0`|`bool`|True if the currency is currency0 (lower address)|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`priceX192`|`uint256`|The price in Q192 fixed-point format|


### convertToSqrtPriceX96

Converts a Q192 price to Uniswap v4 sqrtPriceX96 format

Converts price from Q192 to sqrtPriceX96 format


```solidity
function convertToSqrtPriceX96(uint256 priceX192) internal pure returns (uint160 sqrtPriceX96);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`priceX192`|`uint256`|The price in Q192 fixed-point format|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`sqrtPriceX96`|`uint160`|The square root price in Q96 fixed-point format|


### calculateAmounts

Calculates token amount based on currency amount and price

Uses Q192 fixed-point arithmetic for precision


```solidity
function calculateAmounts(
    uint256 priceX192,
    uint128 currencyAmount,
    bool currencyIsCurrency0,
    uint128 reserveTokenAmount
) internal pure returns (uint128 tokenAmount, uint128 correspondingCurrencyAmount);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`priceX192`|`uint256`|The price in Q192 fixed-point format|
|`currencyAmount`|`uint128`|The amount of currency to convert|
|`currencyIsCurrency0`|`bool`|True if the currency is currency0 (lower address)|
|`reserveTokenAmount`|`uint128`|The reserve supply of the token|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`tokenAmount`|`uint128`|The calculated token amount|
|`correspondingCurrencyAmount`|`uint128`|The corresponding currency amount|


## Errors
### PriceIsZero
Thrown when price is invalid (0 or out of bounds)


```solidity
error PriceIsZero(uint256 price);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`price`|`uint256`|The invalid price in Q96 format in terms of currency1/currency0|

### PriceTooHigh
Thrown when price is too high


```solidity
error PriceTooHigh(uint256 price, uint256 maxPrice);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`price`|`uint256`|The invalid price in Q96 format in terms of currency1/currency0|
|`maxPrice`|`uint256`|The maximum price (type(uint160).max)|

### SqrtPriceX96OutOfBounds
Thrown when price is out of bounds


```solidity
error SqrtPriceX96OutOfBounds(uint160 sqrtPriceX96, uint160 minSqrtPriceX96, uint160 maxSqrtPriceX96);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`sqrtPriceX96`|`uint160`|The invalid sqrt price in Q96 format|
|`minSqrtPriceX96`|`uint160`|The minimum sqrt price (TickMath.MIN_SQRT_PRICE)|
|`maxSqrtPriceX96`|`uint160`|The maximum sqrt price (TickMath.MAX_SQRT_PRICE)|

### AmountOverflow
Thrown when calculated amount exceeds uint128 max value


```solidity
error AmountOverflow(uint256 currencyAmount);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`currencyAmount`|`uint256`|The invalid currency amount|

