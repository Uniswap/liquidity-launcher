// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {BasePositionParams, FullRangeParams, OneSidedParams, TickBounds} from "../types/PositionTypes.sol";
import {ParamsBuilder} from "./ParamsBuilder.sol";
import {ActionsBuilder} from "./ActionsBuilder.sol";
import {TickCalculations} from "./TickCalculations.sol";

/// @title PositionPlanner
/// @notice Simplified library that orchestrates position planning using helper libraries
library StrategyPlanner {
    using TickCalculations for int24;

    /// @notice Plans a full-range position
    function planFullRangePosition(
        BasePositionParams memory baseParams,
        FullRangeParams memory fullRangeParams,
        uint256 paramsArraySize
    ) internal pure returns (bytes memory actions, bytes[] memory params, uint128 liquidity) {
        bool currencyIsCurrency0 = baseParams.currency < baseParams.token;

        // Get tick bounds for full range
        TickBounds memory bounds = TickBounds({
            lowerTick: TickMath.MIN_TICK / baseParams.poolTickSpacing * baseParams.poolTickSpacing,
            upperTick: TickMath.MAX_TICK / baseParams.poolTickSpacing * baseParams.poolTickSpacing
        });

        // Calculate liquidity (already validated in validate() function)
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            baseParams.initialSqrtPriceX96,
            TickMath.getSqrtPriceAtTick(bounds.lowerTick),
            TickMath.getSqrtPriceAtTick(bounds.upperTick),
            currencyIsCurrency0 ? fullRangeParams.currencyAmount : fullRangeParams.tokenAmount,
            currencyIsCurrency0 ? fullRangeParams.tokenAmount : fullRangeParams.currencyAmount
        );

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(currencyIsCurrency0 ? baseParams.currency : baseParams.token),
            currency1: Currency.wrap(currencyIsCurrency0 ? baseParams.token : baseParams.currency),
            fee: baseParams.poolLPFee,
            tickSpacing: baseParams.poolTickSpacing,
            hooks: baseParams.hooks
        });

        actions = ActionsBuilder.buildFullRangeActions();
        params = ParamsBuilder.buildFullRangeParams(
            poolKey, bounds, fullRangeParams, currencyIsCurrency0, paramsArraySize, baseParams.positionRecipient
        );

        // Build actions
        return (actions, params, liquidity);
    }

    /// @notice Plans a one-sided position
    function planOneSidedPosition(
        BasePositionParams memory baseParams,
        OneSidedParams memory oneSidedParams,
        bytes memory existingActions,
        bytes[] memory existingParams
    ) internal pure returns (bytes memory actions, bytes[] memory params) {
        bool currencyIsCurrency0 = baseParams.currency < baseParams.token;

        // Get tick bounds based on position side
        TickBounds memory bounds = currencyIsCurrency0
            ? getLeftSideBounds(baseParams.initialSqrtPriceX96, baseParams.poolTickSpacing)
            : getRightSideBounds(baseParams.initialSqrtPriceX96, baseParams.poolTickSpacing);

        if (bounds.lowerTick == 0 && bounds.upperTick == 0) {
            return (existingActions, ParamsBuilder.truncateParams(existingParams));
        }

        uint128 newLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            baseParams.initialSqrtPriceX96,
            TickMath.getSqrtPriceAtTick(bounds.lowerTick),
            TickMath.getSqrtPriceAtTick(bounds.upperTick),
            currencyIsCurrency0 ? 0 : oneSidedParams.tokenAmount,
            currencyIsCurrency0 ? oneSidedParams.tokenAmount : 0
        );

        if (
            oneSidedParams.existingPoolLiquidity + newLiquidity
                > baseParams.poolTickSpacing.tickSpacingToMaxLiquidityPerTick()
        ) {
            return (existingActions, ParamsBuilder.truncateParams(existingParams));
        }

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(currencyIsCurrency0 ? baseParams.currency : baseParams.token),
            currency1: Currency.wrap(currencyIsCurrency0 ? baseParams.token : baseParams.currency),
            fee: baseParams.poolLPFee,
            tickSpacing: baseParams.poolTickSpacing,
            hooks: baseParams.hooks
        });

        actions = ActionsBuilder.buildOneSidedActions(existingActions);
        params = ParamsBuilder.buildOneSidedParams(
            poolKey,
            bounds,
            oneSidedParams.tokenAmount,
            currencyIsCurrency0,
            existingParams,
            baseParams.positionRecipient
        );

        return (actions, params);
    }

    /// @notice Gets tick bounds for a left-side position (below current tick)
    function getLeftSideBounds(uint160 initialSqrtPriceX96, int24 poolTickSpacing)
        private
        pure
        returns (TickBounds memory bounds)
    {
        int24 initialTick = TickMath.getTickAtSqrtPrice(initialSqrtPriceX96);

        // Check if position is too close to MIN_TICK
        if (initialTick - TickMath.MIN_TICK < poolTickSpacing) {
            return bounds;
        }

        bounds = TickBounds({
            lowerTick: TickMath.MIN_TICK / poolTickSpacing * poolTickSpacing,
            upperTick: initialTick.tickFloor(poolTickSpacing)
        });

        return bounds;
    }

    /// @notice Gets tick bounds for a right-side position (above current tick)
    function getRightSideBounds(uint160 initialSqrtPriceX96, int24 poolTickSpacing)
        private
        pure
        returns (TickBounds memory bounds)
    {
        int24 initialTick = TickMath.getTickAtSqrtPrice(initialSqrtPriceX96);

        // Check if position is too close to MAX_TICK
        if (TickMath.MAX_TICK - initialTick <= poolTickSpacing) {
            return bounds;
        }

        bounds = TickBounds({
            lowerTick: initialTick.tickCeil(poolTickSpacing),
            upperTick: TickMath.MAX_TICK / poolTickSpacing * poolTickSpacing
        });

        return bounds;
    }
}
