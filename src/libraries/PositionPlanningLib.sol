// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {TickCalculations} from "./TickCalculations.sol";

/// @title PositionPlanningLib
/// @notice Library for planning both full-range and one-sided liquidity positions
library PositionPlanningLib {
    using TickCalculations for int24;

    /// @notice Number of params needed for a standalone full-range position
    /// 2 settle + 1 mint position + 2 clear = 5 total
    uint256 public constant FULL_RANGE_ONLY_PARAMS = 5;

    /// @notice Number of params needed for full-range + one-sided position
    /// 2 settle + 1 mint + 2 clear (full range) + 1 settle + 1 mint + 1 clear (one-sided) = 8 total
    uint256 public constant FULL_RANGE_WITH_ONE_SIDED_PARAMS = 8;

    /// @notice Base parameters shared by all position types
    struct BasePositionParams {
        address currency;
        address token;
        uint24 poolLPFee;
        int24 poolTickSpacing;
        uint160 initialSqrtPriceX96;
        address positionRecipient;
        IHooks hooks;
    }

    /// @notice Parameters specific to full-range positions
    struct FullRangeParams {
        uint128 tokenAmount;
        uint128 currencyAmount;
    }

    /// @notice Parameters specific to one-sided positions
    struct OneSidedParams {
        uint256 tokenAmount;
        uint128 currentLiquidity;
    }

    /// @notice Tick boundaries for a position
    struct TickBounds {
        int24 lowerTick;
        int24 upperTick;
    }

    /// @notice Validates liquidity for a full-range position
    /// @param sqrtPriceX96 The current sqrt price
    /// @param tickSpacing The tick spacing of the pool
    /// @param amount0 The amount of token0
    /// @param amount1 The amount of token1
    /// @return liquidity The calculated liquidity
    /// @return isValid Whether the liquidity is within limits
    function validateFullRangeLiquidity(uint160 sqrtPriceX96, int24 tickSpacing, uint128 amount0, uint128 amount1)
        internal
        pure
        returns (uint128 liquidity, bool isValid)
    {
        // Calculate tick bounds for full range
        int24 lowerTick = TickMath.MIN_TICK / tickSpacing * tickSpacing;
        int24 upperTick = TickMath.MAX_TICK / tickSpacing * tickSpacing;

        // Calculate liquidity
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(lowerTick),
            TickMath.getSqrtPriceAtTick(upperTick),
            amount0,
            amount1
        );

        // Check if within limits
        uint128 maxLiquidityPerTick = tickSpacing.tickSpacingToMaxLiquidityPerTick();
        isValid = liquidity <= maxLiquidityPerTick;

        return (liquidity, isValid);
    }

    /// @notice Plans a full-range position
    /// @param baseParams Base parameters for the position
    /// @param fullRangeParams Full range specific parameters
    /// @param paramsArraySize Size of the params array to create (5 for standalone, 8 for combined with one-sided)
    /// @return actions The encoded actions to execute
    /// @return params The parameters for each action
    /// @return liquidity The liquidity amount for the position
    function planFullRangePosition(
        BasePositionParams memory baseParams,
        FullRangeParams memory fullRangeParams,
        uint256 paramsArraySize
    ) internal pure returns (bytes memory actions, bytes[] memory params, uint128 liquidity) {
        // Create pool key with proper currency ordering
        bool isCurrencyFirst = baseParams.currency < baseParams.token;
        PoolKey memory poolKey = _createPoolKey(baseParams, isCurrencyFirst);

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
            isCurrencyFirst ? fullRangeParams.currencyAmount : fullRangeParams.tokenAmount,
            isCurrencyFirst ? fullRangeParams.tokenAmount : fullRangeParams.currencyAmount
        );

        // Build actions
        actions = abi.encodePacked(
            uint8(Actions.SETTLE),
            uint8(Actions.SETTLE),
            uint8(Actions.MINT_POSITION_FROM_DELTAS),
            uint8(Actions.CLEAR_OR_TAKE),
            uint8(Actions.CLEAR_OR_TAKE)
        );

        // Build parameters
        params = new bytes[](paramsArraySize);

        // Settlement parameters
        if (isCurrencyFirst) {
            params[0] = abi.encode(poolKey.currency0, fullRangeParams.currencyAmount, false);
            params[1] = abi.encode(poolKey.currency1, fullRangeParams.tokenAmount, false);
        } else {
            params[0] = abi.encode(poolKey.currency0, fullRangeParams.tokenAmount, false);
            params[1] = abi.encode(poolKey.currency1, fullRangeParams.currencyAmount, false);
        }

        // Position minting parameters
        params[2] = abi.encode(
            poolKey,
            bounds.lowerTick,
            bounds.upperTick,
            isCurrencyFirst ? fullRangeParams.currencyAmount : fullRangeParams.tokenAmount,
            isCurrencyFirst ? fullRangeParams.tokenAmount : fullRangeParams.currencyAmount,
            baseParams.positionRecipient,
            Constants.ZERO_BYTES
        );

        // Clear/take parameters
        params[3] = abi.encode(poolKey.currency0, type(uint256).max);
        params[4] = abi.encode(poolKey.currency1, type(uint256).max);

        return (actions, params, liquidity);
    }

    /// @notice Plans a one-sided position based on token ordering
    /// @return actions The encoded actions to execute
    /// @return params The parameters for each action
    function planOneSidedPosition(
        BasePositionParams memory baseParams,
        OneSidedParams memory oneSidedParams,
        bytes memory existingActions,
        bytes[] memory existingParams
    ) internal pure returns (bytes memory actions, bytes[] memory params) {
        // Determine position side based on currency ordering
        bool isCurrencyFirst = baseParams.currency < baseParams.token;

        // Calculate tick bounds and check validity
        (TickBounds memory bounds, bool isValid) = isCurrencyFirst
            ? _getLeftSideBounds(baseParams.initialSqrtPriceX96, baseParams.poolTickSpacing)
            : _getRightSideBounds(baseParams.initialSqrtPriceX96, baseParams.poolTickSpacing);

        if (!isValid) {
            return (existingActions, _truncateParams(existingParams));
        }

        // Check liquidity limits
        uint128 newLiquidity = _calculateOneSidedLiquidity(
            baseParams.initialSqrtPriceX96, bounds, oneSidedParams.tokenAmount, isCurrencyFirst
        );

        if (!_isWithinLiquidityLimit(oneSidedParams.currentLiquidity, newLiquidity, baseParams.poolTickSpacing)) {
            return (existingActions, _truncateParams(existingParams));
        }

        // Build the position plan
        return _buildOneSidedPlan(
            baseParams, oneSidedParams.tokenAmount, bounds, existingActions, existingParams, isCurrencyFirst
        );
    }

    /// @notice Gets tick bounds for a left-side position (below current tick)
    function _getLeftSideBounds(uint160 initialSqrtPriceX96, int24 poolTickSpacing)
        private
        pure
        returns (TickBounds memory bounds, bool isValid)
    {
        int24 initialTick = TickMath.getTickAtSqrtPrice(initialSqrtPriceX96);

        // Check if position is too close to MIN_TICK
        if (initialTick - TickMath.MIN_TICK < poolTickSpacing) {
            return (bounds, false);
        }

        bounds = TickBounds({
            lowerTick: TickMath.MIN_TICK / poolTickSpacing * poolTickSpacing,
            upperTick: initialTick.tickFloor(poolTickSpacing)
        });

        return (bounds, true);
    }

    /// @notice Gets tick bounds for a right-side position (above current tick)
    function _getRightSideBounds(uint160 initialSqrtPriceX96, int24 poolTickSpacing)
        private
        pure
        returns (TickBounds memory bounds, bool isValid)
    {
        int24 initialTick = TickMath.getTickAtSqrtPrice(initialSqrtPriceX96);

        // Check if position is too close to MAX_TICK
        if (TickMath.MAX_TICK - initialTick <= poolTickSpacing) {
            return (bounds, false);
        }

        bounds = TickBounds({
            lowerTick: initialTick.tickCeil(poolTickSpacing),
            upperTick: TickMath.MAX_TICK / poolTickSpacing * poolTickSpacing
        });

        return (bounds, true);
    }

    /// @notice Builds the one-sided position plan with actions and parameters
    function _buildOneSidedPlan(
        BasePositionParams memory baseParams,
        uint256 tokenAmount,
        TickBounds memory bounds,
        bytes memory existingActions,
        bytes[] memory existingParams,
        bool isCurrencyFirst
    ) private pure returns (bytes memory actions, bytes[] memory params) {
        // Set up settlement parameters for token
        existingParams[5] = abi.encode(Currency.wrap(baseParams.token), tokenAmount, false);

        // Create pool key and position parameters
        PoolKey memory poolKey = _createPoolKey(baseParams, isCurrencyFirst);

        existingParams[6] = abi.encode(
            poolKey,
            bounds.lowerTick,
            bounds.upperTick,
            isCurrencyFirst ? 0 : tokenAmount, // amount0
            isCurrencyFirst ? tokenAmount : 0, // amount1
            baseParams.positionRecipient,
            Constants.ZERO_BYTES
        );

        // Set up clearing parameters
        existingParams[7] = abi.encode(Currency.wrap(baseParams.token), type(uint256).max);

        // Append actions
        actions = abi.encodePacked(
            existingActions,
            uint8(Actions.SETTLE),
            uint8(Actions.MINT_POSITION_FROM_DELTAS),
            uint8(Actions.CLEAR_OR_TAKE)
        );

        return (actions, existingParams);
    }

    /// @notice Creates a pool key with proper currency ordering
    function _createPoolKey(BasePositionParams memory baseParams, bool isCurrencyFirst)
        private
        pure
        returns (PoolKey memory)
    {
        return PoolKey({
            currency0: Currency.wrap(isCurrencyFirst ? baseParams.currency : baseParams.token),
            currency1: Currency.wrap(isCurrencyFirst ? baseParams.token : baseParams.currency),
            fee: baseParams.poolLPFee,
            tickSpacing: baseParams.poolTickSpacing,
            hooks: baseParams.hooks
        });
    }

    /// @notice Calculates liquidity for a one-sided position
    function _calculateOneSidedLiquidity(
        uint160 currentSqrtPrice,
        TickBounds memory bounds,
        uint256 tokenAmount,
        bool isCurrencyFirst
    ) private pure returns (uint128) {
        return LiquidityAmounts.getLiquidityForAmounts(
            currentSqrtPrice,
            TickMath.getSqrtPriceAtTick(bounds.lowerTick),
            TickMath.getSqrtPriceAtTick(bounds.upperTick),
            isCurrencyFirst ? 0 : tokenAmount,
            isCurrencyFirst ? tokenAmount : 0
        );
    }

    /// @notice Checks if liquidity is within allowed limits
    function _isWithinLiquidityLimit(uint128 currentLiquidity, uint128 newLiquidity, int24 tickSpacing)
        private
        pure
        returns (bool)
    {
        return currentLiquidity + newLiquidity <= tickSpacing.tickSpacingToMaxLiquidityPerTick();
    }

    /// @notice Truncates parameters array to full-range only size
    function _truncateParams(bytes[] memory params) private pure returns (bytes[] memory) {
        bytes[] memory truncated = new bytes[](FULL_RANGE_ONLY_PARAMS);
        for (uint256 i = 0; i < FULL_RANGE_ONLY_PARAMS; i++) {
            truncated[i] = params[i];
        }
        return truncated;
    }
}
