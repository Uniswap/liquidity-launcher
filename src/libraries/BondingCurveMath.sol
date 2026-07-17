// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";

/// @title BondingCurveMath
/// @notice Computes a token split whose completed curve position pairs into full-range liquidity
library BondingCurveMath {
    /// @notice Thrown when the curve does not move from a higher to a lower raw v4 price
    error InvalidPriceRange();

    /// @notice Splits supply between a token1 curve position and its full-range graduation reserve
    /// @dev Accounts for the finite minimum and maximum usable ticks of the final position.
    function splitSupply(
        uint256 totalSupply,
        uint160 initialSqrtPriceX96,
        uint160 graduationSqrtPriceX96,
        int24 tickSpacing
    ) internal pure returns (uint256 curveSupply, uint256 reserveSupply) {
        if (graduationSqrtPriceX96 >= initialSqrtPriceX96) revert InvalidPriceRange();

        uint160 minSqrtPriceX96 = TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(tickSpacing));
        uint160 maxSqrtPriceX96 = TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(tickSpacing));

        // reserve / curve for a completed [graduation, initial] token1 position followed by a full-range position.
        uint256 lowerRatioX96 =
            FullMath.mulDiv(graduationSqrtPriceX96 - minSqrtPriceX96, FixedPoint96.Q96, initialSqrtPriceX96);
        uint256 upperRatioX96 =
            FullMath.mulDiv(maxSqrtPriceX96, FixedPoint96.Q96, maxSqrtPriceX96 - graduationSqrtPriceX96);
        uint256 reservePerCurveX96 = FullMath.mulDiv(lowerRatioX96, upperRatioX96, FixedPoint96.Q96);

        curveSupply = FullMath.mulDiv(totalSupply, FixedPoint96.Q96, FixedPoint96.Q96 + reservePerCurveX96);
        reserveSupply = totalSupply - curveSupply;
    }

    /// @notice Returns the token0 principal held by a completed token1 curve position
    function completedCurvePrincipal(uint128 liquidity, uint160 graduationSqrtPriceX96, uint160 initialSqrtPriceX96)
        internal
        pure
        returns (uint256)
    {
        return SqrtPriceMath.getAmount0Delta(graduationSqrtPriceX96, initialSqrtPriceX96, liquidity, false);
    }
}
