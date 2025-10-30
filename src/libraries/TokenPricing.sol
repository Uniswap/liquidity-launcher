// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Math} from "@openzeppelin-latest/contracts/utils/math/Math.sol";

/// @title TokenPricing
/// @notice Library for pricing operations including price conversions and token amount calculations
/// @dev Handles conversions between different price representations and calculates swap amounts
library TokenPricing {
    /// @notice Thrown when price is invalid (0 or out of bounds)
    /// @param price The invalid price in Q96 format in terms of currency1/currency0
    error InvalidPrice(uint256 price);

    /// @notice Thrown when calculated amount exceeds uint128 max value
    /// @param currencyAmount The invalid currency amount
    error AmountOverflow(uint256 currencyAmount);

    /// @notice Q192 format: 192-bit fixed-point number representation
    /// @dev Used for intermediate calculations to maintain precision
    uint256 public constant Q192 = 2 ** 192;

    /// @notice Converts a Q96 price to Uniswap v4 X192 format in terms of currency1/currency0
    /// @dev Converts price from Q96 to X192 format
    /// @param price The price in Q96 fixed-point format (96 bits of fractional precision)
    /// @param currencyIsCurrency0 True if the currency is currency0 (lower address)
    /// @return priceX192 The price in Q192 fixed-point format
    function convertToPriceX192(uint256 price, bool currencyIsCurrency0) internal pure returns (uint256 priceX192) {
        if (price == 0) {
            revert InvalidPrice(price);
        }
        // If currency is currency0, we need to invert the price (price = currency1/currency0)
        if (currencyIsCurrency0) {
            // Inverts the Q96 price: (2^192 / priceQ96) = (2^96 / actualPrice), maintaining Q96 format
            price = (1 << (FixedPoint96.RESOLUTION * 2)) / price;
        }

        // Check price bounds after potential inversion
        if (price > type(uint160).max) {
            revert InvalidPrice(price);
        }

        // Convert from Q96 to X192 format by shifting left 96 bits (will not overflow since price is less than or equal to type(uint160).max)
        priceX192 = price << FixedPoint96.RESOLUTION;
        return priceX192;
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
            revert InvalidPrice(priceX192);
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
    /// @return leftoverCurrency The leftover currency amount
    /// @return correspondingCurrencyAmount The corresponding currency amount
    function calculateAmounts(
        uint256 priceX192,
        uint128 currencyAmount,
        bool currencyIsCurrency0,
        uint128 reserveSupply
    ) internal pure returns (uint128 tokenAmount, uint128 leftoverCurrency, uint128 correspondingCurrencyAmount) {
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

            // currencyAmount is already validated to be less than or equal to type(uint128).max so leftoverCurrency is also less than or equal to type(uint128).max
            leftoverCurrency = currencyAmount - correspondingCurrencyAmount;
            tokenAmount = reserveSupply; // tokenAmount will never be greater than reserveSupply
        } else {
            correspondingCurrencyAmount = currencyAmount;
            // tokenAmountUint256 is less than or equal to reserveSupply which is less than or equal to type(uint128).max
            tokenAmount = uint128(tokenAmountUint256);
        }

        return (tokenAmount, leftoverCurrency, correspondingCurrencyAmount);
    }
}
