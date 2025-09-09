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
    error InvalidPrice(uint256 price);

    /// @notice Q192 format: 192-bit fixed-point number representation
    /// @dev Used for intermediate calculations to maintain precision
    uint256 public constant Q192 = 2 ** 192;

    /// @notice Converts a regular price to Uniswap V4 price formats
    /// @dev Converts price to both X192 and sqrtX96 formats
    /// @param price The price as a regular uint256
    /// @param currencyIsCurrency0 True if the currency is currency0 (lower address)
    /// @return priceX192 The price in Q192 fixed-point format
    /// @return sqrtPriceX96 The square root price in Q96 fixed-point format
    function convertPrice(uint256 price, bool currencyIsCurrency0)
        internal
        pure
        returns (uint256 priceX192, uint160 sqrtPriceX96)
    {
        if (price == 0) {
            revert InvalidPrice(price);
        }
        // If currency is currency0, we need to invert the price (price = currency1/currency0)
        if (currencyIsCurrency0) {
            price = FullMath.mulDiv(1 << FixedPoint96.RESOLUTION, 1 << FixedPoint96.RESOLUTION, price);
        }

        // Convert to X192 format (may overflow if price > type(uint160).max)
        priceX192 = price << FixedPoint96.RESOLUTION;

        // Calculate square root for Uniswap v4's sqrtPriceX96 format
        // Note: This will lose some precision and be rounded down
        sqrtPriceX96 = uint160(Math.sqrt(priceX192));

        if (sqrtPriceX96 < TickMath.MIN_SQRT_PRICE || sqrtPriceX96 > TickMath.MAX_SQRT_PRICE) {
            revert InvalidPrice(price);
        }

        return (priceX192, sqrtPriceX96);
    }

    /// @notice Calculates token amount based on currency amount and price
    /// @dev Uses Q192 fixed-point arithmetic for precision
    /// @param priceX192 The price in Q192 fixed-point format
    /// @param currencyAmount The amount of currency to convert
    /// @param currencyIsCurrency0 True if the currency is currency0 (lower address)
    /// @return The calculated token amount
    function calculateTokenAmount(uint256 priceX192, uint128 currencyAmount, bool currencyIsCurrency0)
        internal
        pure
        returns (uint128)
    {
        return currencyIsCurrency0
            ? uint128(FullMath.mulDiv(priceX192, currencyAmount, Q192))
            : uint128(FullMath.mulDiv(currencyAmount, Q192, priceX192));
    }
}
