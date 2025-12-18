// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title TokenPricing
/// @notice Library for pricing operations including price conversions and token amount calculations
/// @dev Handles conversions between different price representations and calculates swap amounts
library TokenPricing {
    /// @notice Thrown when price is invalid (0 or out of bounds)
    /// @param price The invalid price in Q96 format in terms of currency1/currency0
    error PriceIsZero(uint256 price);

    /// @notice Thrown when price is too high
    /// @param price The invalid price in Q96 format in terms of currency1/currency0
    /// @param maxPrice The maximum price (type(uint160).max)
    error PriceTooHigh(uint256 price, uint256 maxPrice);

    /// @notice Thrown when price is out of bounds
    /// @param sqrtPriceX96 The invalid sqrt price in Q96 format
    /// @param minSqrtPriceX96 The minimum sqrt price (TickMath.MIN_SQRT_PRICE)
    /// @param maxSqrtPriceX96 The maximum sqrt price (TickMath.MAX_SQRT_PRICE)
    error SqrtPriceX96OutOfBounds(uint160 sqrtPriceX96, uint160 minSqrtPriceX96, uint160 maxSqrtPriceX96);

    /// @notice Thrown when calculated amount exceeds uint128 max value
    /// @param currencyAmount The invalid currency amount
    error AmountOverflow(uint256 currencyAmount);

    /// @notice Q192 format: 192-bit fixed-point number representation
    /// @dev Used for intermediate calculations to maintain precision
    uint256 public constant Q192 = 1 << 192;

    /// @notice Converts a Q96 price to Uniswap v4 X192 format in terms of currency1/currency0
    /// @dev Converts price from Q96 to X192 format
    /// @param price The price in Q96 fixed-point format (96 bits of fractional precision)
    /// @param currencyIsCurrency0 True if the currency is currency0 (lower address)
    /// @return priceX192 The price in Q192 fixed-point format
    function convertToPriceX192(uint256 price, bool currencyIsCurrency0) internal pure returns (uint256 priceX192) {
        // Prevent division by zero
        if (price == 0) {
            revert PriceIsZero(price);
        }

        // If currency is currency0, we need to invert the price (price = currency1/currency0)
        if (currencyIsCurrency0) {
            // If the inverted price is greater than uint160.max it will revert in FullMath
            // Catch it explicitly here and revert with PriceTooHigh
            if ((Q192 / price) >> 160 != 0) {
                revert PriceTooHigh(Q192 / price, type(uint160).max);
            }
            // Invert the Q96 price using FullMath with 512 bits of precision
            // Equivalent to finding the inverse then shifting left 96 bits
            priceX192 = FullMath.mulDiv(Q192, FixedPoint96.Q96, price);
        } else {
            // Otherwise, revert if the price exceeds uint160.max
            if (price >> 160 != 0) {
                revert PriceTooHigh(price, type(uint160).max);
            }
            priceX192 = price << FixedPoint96.RESOLUTION;
        }
    }

    /// @notice Converts a Q192 price to Uniswap v4 sqrtPriceX96 format
    /// @dev Converts price from Q192 to sqrtPriceX96 format
    /// @param priceX192 The price in Q192 fixed-point format
    /// @return sqrtPriceX96 The square root price in Q96 fixed-point format
    function convertToSqrtPriceX96(uint256 priceX192) internal pure returns (uint160 sqrtPriceX96) {
        // Calculate square root for Uniswap v4's sqrtPriceX96 format
        // This will lose some precision and be rounded down
        sqrtPriceX96 = uint160(Math.sqrt(priceX192));

        if (sqrtPriceX96 < TickMath.MIN_SQRT_PRICE || sqrtPriceX96 > TickMath.MAX_SQRT_PRICE) {
            revert SqrtPriceX96OutOfBounds(sqrtPriceX96, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE);
        }

        return sqrtPriceX96;
    }

    /// @notice Calculates token amount based on currency amount and price
    /// @dev Uses Q192 fixed-point arithmetic for precision
    /// @param priceX192 The price in Q192 fixed-point format
    /// @param currencyAmount The amount of currency to convert
    /// @param currencyIsCurrency0 True if the currency is currency0 (lower address)
    /// @param reserveSupply The reserve supply of the token
    /// @return tokenAmount The calculated token amount
    /// @return correspondingCurrencyAmount The corresponding currency amount
    function calculateAmounts(
        uint256 priceX192,
        uint128 currencyAmount,
        bool currencyIsCurrency0,
        uint128 reserveSupply
    ) internal pure returns (uint128 tokenAmount, uint128 correspondingCurrencyAmount) {
        // calculates corresponding token amount based on currency amount and price
        uint256 tokenAmountUint256 = currencyIsCurrency0
            ? FullMath.mulDiv(priceX192, currencyAmount, Q192)
            : FullMath.mulDiv(currencyAmount, Q192, priceX192);

        // if token amount is greater than reserve supply, there is leftover currency. we need to find new currency amount based on reserve supply and price.
        if (tokenAmountUint256 > reserveSupply) {
            uint256 correspondingCurrencyAmountUint256 = currencyIsCurrency0
                ? FullMath.mulDiv(reserveSupply, Q192, priceX192)
                : FullMath.mulDiv(priceX192, reserveSupply, Q192);

            if (correspondingCurrencyAmountUint256 > type(uint128).max) {
                revert AmountOverflow(correspondingCurrencyAmountUint256);
            }

            correspondingCurrencyAmount = uint128(correspondingCurrencyAmountUint256);

            tokenAmount = reserveSupply; // tokenAmount will never be greater than reserveSupply
        } else {
            correspondingCurrencyAmount = currencyAmount;
            // tokenAmountUint256 is less than or equal to reserveSupply which is less than or equal to type(uint128).max
            tokenAmount = uint128(tokenAmountUint256);
        }

        return (tokenAmount, correspondingCurrencyAmount);
    }
}
