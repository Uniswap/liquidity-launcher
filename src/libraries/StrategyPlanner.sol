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
    using ActionsBuilder for *;
    using ParamsBuilder for *;

    /// @notice Creates the actions and parameters needed to mint a full range position on the position manager
    /// @param actions The actions for the call to position manager
    /// @param params The parameters for the call to position manager
    /// @param baseParams The base parameters for the position
    /// @param fullRangeParams The amounts of currency and token that will be used to mint the position
    function planFullRangePosition(
        bytes memory actions,
        bytes[] memory params,
        BasePositionParams memory baseParams,
        FullRangeParams memory fullRangeParams
    ) internal returns (bytes memory, bytes[] memory) {
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

        actions = actions.addMint().addSettle().addSettle();
        params = params.addFullRangeParams(
            fullRangeParams, poolKey, bounds, currencyIsCurrency0, baseParams.positionRecipient, baseParams.liquidity
        );

        // Build actions
        return (actions, params);
    }

    /// @notice Creates the actions and parameters needed to mint a one-sided position on the position manager
    /// @param actions The actions for the call to position manager
    /// @param params The parameters for the call to position manager
    /// @param baseParams The base parameters for the position
    /// @param oneSidedParams The amounts of token that will be used to mint the position
    function planOneSidedPosition(
        bytes memory actions,
        bytes[] memory params,
        BasePositionParams memory baseParams,
        OneSidedParams memory oneSidedParams
    ) internal returns (bytes memory, bytes[] memory) {
        bool currencyIsCurrency0 = baseParams.currency < baseParams.poolToken;

        // Get tick bounds based on position side
        TickBounds memory bounds = currencyIsCurrency0 == oneSidedParams.inToken
            ? getLeftSideBounds(baseParams.initialSqrtPriceX96, baseParams.poolTickSpacing)
            : getRightSideBounds(baseParams.initialSqrtPriceX96, baseParams.poolTickSpacing);

        // If the tick bounds are 0,0 (which means the current tick is too close to MIN_TICK or MAX_TICK), return the existing actions and parameters
        // that will build a full range position
        if (bounds.lowerTick == 0 && bounds.upperTick == 0) {
            return (actions, params);
        }

        // If this overflows, the transaction will revert and no position will be created
        uint128 newLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            baseParams.initialSqrtPriceX96,
            TickMath.getSqrtPriceAtTick(bounds.lowerTick),
            TickMath.getSqrtPriceAtTick(bounds.upperTick),
            currencyIsCurrency0 == oneSidedParams.inToken ? 0 : oneSidedParams.amount,
            currencyIsCurrency0 == oneSidedParams.inToken ? oneSidedParams.amount : 0
        );

        if (
            newLiquidity == 0
                || baseParams.liquidity + newLiquidity > baseParams.poolTickSpacing.tickSpacingToMaxLiquidityPerTick()
        ) {
            return (actions, params);
        }

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(currencyIsCurrency0 ? baseParams.currency : baseParams.poolToken),
            currency1: Currency.wrap(currencyIsCurrency0 ? baseParams.poolToken : baseParams.currency),
            fee: baseParams.poolLPFee,
            tickSpacing: baseParams.poolTickSpacing,
            hooks: baseParams.hooks
        });

        actions = ActionsBuilder.addMint(actions);
        params = params.addOneSidedParams(
            oneSidedParams, poolKey, bounds, currencyIsCurrency0, baseParams.positionRecipient, newLiquidity
        );

        return (actions, params);
    }

    /// @notice Plans the final take pair action and parameters
    /// @param actions The existing actions for the position which may be extended with the new actions for the final take pair
    /// @param params The existing parameters for the position which may be extended with the new parameters for the final take pair
    /// @param baseParams The base parameters for the position
    function planFinalTakePair(bytes memory actions, bytes[] memory params, BasePositionParams memory baseParams)
        internal
        returns (bytes memory, bytes[] memory)
    {
        bool currencyIsCurrency0 = baseParams.currency < baseParams.poolToken;
        actions = actions.addTakePair();
        params = params.addTakePairParams(
            currencyIsCurrency0 ? baseParams.currency : baseParams.poolToken,
            currencyIsCurrency0 ? baseParams.poolToken : baseParams.currency
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
