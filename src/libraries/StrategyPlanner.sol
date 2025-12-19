// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {BasePositionParams, TickBounds} from "../types/PositionTypes.sol";
import {ParamsBuilder} from "./ParamsBuilder.sol";
import {ActionsBuilder} from "./ActionsBuilder.sol";
import {TickCalculations} from "./TickCalculations.sol";
import {DynamicArrayLib} from "./DynamicArrayLib.sol";

/// @title PositionPlanner
/// @notice Simplified library that orchestrates position planning using helper libraries
library StrategyPlanner {
    using DynamicArrayLib for bytes[];
    using TickCalculations for int24;
    using ParamsBuilder for *;

    error InvalidOneSidedPosition(uint128 tokenAmount, uint128 currencyAmount);

    /// @notice Creates the actions and parameters needed to mint a full range position on the position manager
    /// @param baseParams The base parameters for the position
    /// @param tokenAmount The amount of token to mint
    /// @param currencyAmount The amount of currency to mint
    /// @return param The parameter needed to mint a full range position on the position manager
    function planFullRangePosition(BasePositionParams memory baseParams, uint128 tokenAmount, uint128 currencyAmount)
        internal
        pure
        returns (bytes memory param)
    {
        bool currencyIsCurrency0 = baseParams.currency < baseParams.poolToken;

        // Get tick bounds for full range
        TickBounds memory bounds = TickBounds({
            lowerTick: TickMath.minUsableTick(baseParams.poolTickSpacing),
            upperTick: TickMath.maxUsableTick(baseParams.poolTickSpacing)
        });

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(currencyIsCurrency0 ? baseParams.currency : baseParams.poolToken),
            currency1: Currency.wrap(currencyIsCurrency0 ? baseParams.poolToken : baseParams.currency),
            fee: baseParams.poolLPFee,
            tickSpacing: baseParams.poolTickSpacing,
            hooks: baseParams.hooks
        });

        param = ParamsBuilder.addMintParam(
            poolKey, bounds, baseParams.liquidity, tokenAmount, currencyAmount, baseParams.positionRecipient
        );
    }

    /// @notice Creates the actions and parameters needed to mint a one-sided position on the position manager
    /// @param baseParams The base parameters for the position
    /// @param tokenAmount The amount of token to mint
    /// @param currencyAmount The amount of currency to mint
    /// @return param The parameters needed to mint a full range position with one-sided position on the position manager
    function planOneSidedPosition(BasePositionParams memory baseParams, uint128 tokenAmount, uint128 currencyAmount)
        internal
        pure
        returns (bytes memory param)
    {
        // Require either tokenAmount or currencyAmount to be 0, but not both
        if ((tokenAmount != 0 && currencyAmount != 0) || tokenAmount == currencyAmount) {
            revert InvalidOneSidedPosition(tokenAmount, currencyAmount);
        }
        bool currencyIsCurrency0 = baseParams.currency < baseParams.poolToken;
        bool inToken = currencyAmount == 0;

        // Get tick bounds based on position side
        TickBounds memory bounds = currencyIsCurrency0 == inToken
            ? getLeftSideBounds(baseParams.initialSqrtPriceX96, baseParams.poolTickSpacing)
            : getRightSideBounds(baseParams.initialSqrtPriceX96, baseParams.poolTickSpacing);

        // If the tick bounds are 0,0 (which means the current tick is too close to MIN_TICK or MAX_TICK) do not create a one-sided position
        if (bounds.lowerTick == 0 && bounds.upperTick == 0) {
            return bytes("");
        }

        // If this overflows, the transaction will revert and no position will be created
        uint128 newLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            baseParams.initialSqrtPriceX96,
            TickMath.getSqrtPriceAtTick(bounds.lowerTick),
            TickMath.getSqrtPriceAtTick(bounds.upperTick),
            currencyIsCurrency0 == inToken ? 0 : tokenAmount,
            currencyIsCurrency0 == inToken ? currencyAmount : 0
        );

        if (
            newLiquidity == 0
                || baseParams.liquidity + newLiquidity > baseParams.poolTickSpacing.tickSpacingToMaxLiquidityPerTick()
        ) {
            return bytes("");
        }

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(currencyIsCurrency0 ? baseParams.currency : baseParams.poolToken),
            currency1: Currency.wrap(currencyIsCurrency0 ? baseParams.poolToken : baseParams.currency),
            fee: baseParams.poolLPFee,
            tickSpacing: baseParams.poolTickSpacing,
            hooks: baseParams.hooks
        });

        param = ParamsBuilder.addMintParam(
            poolKey, bounds, newLiquidity, tokenAmount, currencyAmount, baseParams.positionRecipient
        );
    }

    /// @notice Plans the final take pair action and parameters
    /// @param baseParams The base parameters for the position
    /// @return param The parameter needed to take the pair using the position manager
    function planFinalTakePair(BasePositionParams memory baseParams) internal view returns (bytes memory param) {
        bool currencyIsCurrency0 = baseParams.currency < baseParams.poolToken;
        param = ParamsBuilder.addTakePairParam(
            address(currencyIsCurrency0 ? baseParams.currency : baseParams.poolToken),
            address(currencyIsCurrency0 ? baseParams.poolToken : baseParams.currency)
        );
    }

    /// @notice Gets tick bounds for a left-side position (below current tick)
    /// @param initialSqrtPriceX96 The initial sqrt price of the position
    /// @param poolTickSpacing The tick spacing of the pool
    /// @return bounds The tick bounds for the left-side position (returns 0,0 if the current tick is too close to MIN_TICK)
    function getLeftSideBounds(uint160 initialSqrtPriceX96, int24 poolTickSpacing)
        private
        pure
        returns (TickBounds memory bounds)
    {
        int24 initialTick = TickMath.getTickAtSqrtPrice(initialSqrtPriceX96);

        // Check if position is too close to MIN_TICK. If so, return a lower tick and upper tick of 0
        if (initialTick - TickMath.MIN_TICK < poolTickSpacing) {
            return bounds;
        }

        bounds = TickBounds({
            lowerTick: TickMath.minUsableTick(poolTickSpacing), // Rounds to the nearest multiple of tick spacing (rounds towards 0 since MIN_TICK is negative)
            upperTick: initialTick.tickFloor(poolTickSpacing) // Rounds to the nearest multiple of tick spacing if needed (rounds toward -infinity)
        });

        return bounds;
    }

    /// @notice Gets tick bounds for a right-side position (above current tick)
    /// @param initialSqrtPriceX96 The initial sqrt price of the position
    /// @param poolTickSpacing The tick spacing of the pool
    /// @return bounds The tick bounds for the right-side position (returns 0,0 if the current tick is too close to MAX_TICK)
    function getRightSideBounds(uint160 initialSqrtPriceX96, int24 poolTickSpacing)
        private
        pure
        returns (TickBounds memory bounds)
    {
        int24 initialTick = TickMath.getTickAtSqrtPrice(initialSqrtPriceX96);

        // Check if position is too close to MAX_TICK. If so, return a lower tick and upper tick of 0
        if (TickMath.MAX_TICK - initialTick <= poolTickSpacing) {
            return bounds;
        }

        bounds = TickBounds({
            lowerTick: initialTick.tickStrictCeil(poolTickSpacing), // Rounds toward +infinity to the nearest multiple of tick spacing
            upperTick: TickMath.maxUsableTick(poolTickSpacing) // Rounds to the nearest multiple of tick spacing (rounds toward 0 since MAX_TICK is positive)
        });

        return bounds;
    }
}
