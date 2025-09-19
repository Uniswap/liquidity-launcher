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
    using ParamsBuilder for *;

    /// @notice Creates the actions and parameters needed to mint a full range position on the position manager
    /// @param baseParams The base parameters for the position
    /// @param fullRangeParams The amounts of currency and token that will be used to mint the position
    /// @param paramsArraySize The size of the parameters array (either 5 if it's a standalone full range position,
    ///                        or 8 if it's a full range position with one sided position)
    /// @return actions The actions needed to mint a full range position on the position manager
    /// @return params The parameters needed to mint a full range position on the position manager
    function planFullRangePosition(
        BasePositionParams memory baseParams,
        FullRangeParams memory fullRangeParams,
        uint256 paramsArraySize
    ) internal pure returns (bytes memory actions, bytes[] memory params) {
        bool currencyIsCurrency0 = baseParams.currency < baseParams.token;

        // Get tick bounds for full range
        TickBounds memory bounds = TickBounds({
            lowerTick: TickMath.MIN_TICK / baseParams.poolTickSpacing * baseParams.poolTickSpacing,
            upperTick: TickMath.MAX_TICK / baseParams.poolTickSpacing * baseParams.poolTickSpacing
        });

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(currencyIsCurrency0 ? baseParams.currency : baseParams.token),
            currency1: Currency.wrap(currencyIsCurrency0 ? baseParams.token : baseParams.currency),
            fee: baseParams.poolLPFee,
            tickSpacing: baseParams.poolTickSpacing,
            hooks: baseParams.hooks
        });

        actions = ActionsBuilder.buildFullRangeActions();
        params = fullRangeParams.buildFullRangeParams(
            poolKey, bounds, currencyIsCurrency0, paramsArraySize, baseParams.positionRecipient
        );

        // Build actions
        return (actions, params);
    }

    /// @notice Creates the actions and parameters needed to mint a one-sided position on the position manager
    /// @param baseParams The base parameters for the position
    /// @param oneSidedParams The amounts of token that will be used to mint the position
    /// @param existingActions The existing actions needed to mint a full range position on the position manager (Output of planFullRangePosition())
    /// @param existingParams The existing parameters needed to mint a full range position on the position manager (Output of planFullRangePosition())
    /// @return actions The actions needed to mint a full range position with one-sided position on the position manager
    /// @return params The parameters needed to mint a full range position with one-sided position on the position manager
    function planOneSidedPosition(
        BasePositionParams memory baseParams,
        OneSidedParams memory oneSidedParams,
        bytes memory existingActions,
        bytes[] memory existingParams
    ) internal pure returns (bytes memory actions, bytes[] memory params) {
        bool currencyIsCurrency0 = baseParams.currency < baseParams.token;

        // Get tick bounds based on position side
        TickBounds memory bounds = currencyIsCurrency0 == oneSidedParams.inToken
            ? getLeftSideBounds(baseParams.initialSqrtPriceX96, baseParams.poolTickSpacing)
            : getRightSideBounds(baseParams.initialSqrtPriceX96, baseParams.poolTickSpacing);

        // If the tick bounds are 0,0 (which means the current tick is too close to MIN_TICK or MAX_TICK), return the existing actions and parameters
        // that will build a full range position
        if (bounds.lowerTick == 0 && bounds.upperTick == 0) {
            return (existingActions, existingParams.truncateParams());
        }

        uint128 newLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            baseParams.initialSqrtPriceX96,
            TickMath.getSqrtPriceAtTick(bounds.lowerTick),
            TickMath.getSqrtPriceAtTick(bounds.upperTick),
            currencyIsCurrency0 == oneSidedParams.inToken ? 0 : oneSidedParams.amount,
            currencyIsCurrency0 == oneSidedParams.inToken ? oneSidedParams.amount : 0
        );

        if (baseParams.liquidity + newLiquidity > baseParams.poolTickSpacing.tickSpacingToMaxLiquidityPerTick()) {
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
        params = oneSidedParams.buildOneSidedParams(
            poolKey, bounds, currencyIsCurrency0, existingParams, baseParams.positionRecipient
        );

        return (actions, params);
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
            lowerTick: TickMath.MIN_TICK / poolTickSpacing * poolTickSpacing, // Rounds to the nearest multiple of tick spacing (rounds towards 0 since MIN_TICK is negative)
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
            upperTick: TickMath.MAX_TICK / poolTickSpacing * poolTickSpacing // Rounds to the nearest multiple of tick spacing (rounds toward 0 since MAX_TICK is positive)
        });

        return bounds;
    }
}
