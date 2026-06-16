// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title TokenPricing
/// @notice Price conversion helpers for initializing Uniswap v4 pools.
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

    /// @notice Q192 format: 192-bit fixed-point number representation
    /// @dev Used for intermediate calculations to maintain precision
    uint256 public constant Q192 = 1 << 192;

    /// @notice Converts an X96 currency-per-token price into v4's X192 price format.
    /// @dev Inverts the price when currency sorts before token so the result is always currency1/currency0.
    /// @param price The price in Q96 fixed-point format.
    /// @param currencyIsCurrency0 True if the currency is currency0 (lower address)
    /// @return priceX192 The price in Q192 fixed-point format
    function convertToPriceX192(uint256 price, bool currencyIsCurrency0) internal pure returns (uint256 priceX192) {
        if (price == 0) {
            revert PriceIsZero(price);
        }

        if (currencyIsCurrency0) {
            if ((Q192 / price) >> 160 != 0) {
                revert PriceTooHigh(Q192 / price, type(uint160).max);
            }
            priceX192 = FullMath.mulDiv(Q192, FixedPoint96.Q96, price);
        } else {
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
        sqrtPriceX96 = uint160(Math.sqrt(priceX192));

        if (sqrtPriceX96 < TickMath.MIN_SQRT_PRICE || sqrtPriceX96 > TickMath.MAX_SQRT_PRICE) {
            revert SqrtPriceX96OutOfBounds(sqrtPriceX96, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE);
        }

        return sqrtPriceX96;
    }
}
