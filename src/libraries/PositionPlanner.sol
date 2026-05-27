// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {TickCalculations} from "./TickCalculations.sol";
import {Plan, Position, PositionDefinition} from "../types/PositionPlannerTypes.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @title PositionPlanner
/// @notice Converts weighted position configurations into a deterministic PositionManager plan.
library PositionPlanner {
    using TickCalculations for int24;

    /// @notice Absolute tick boundaries for a resolved position
    struct TickBounds {
        int24 lowerTick;
        int24 upperTick;
    }

    /// @notice Position allocations are expressed in millionths (1e7 = 100%)
    uint24 internal constant MPS = 1e7;
    /// @notice Reference liquidity used to quote weighted token consumption
    uint128 internal constant LIQUIDITY_PRECISION = 1e18;
    /// @notice The maximum number of positions that can be included in a plan to prevent OOG
    uint24 public constant MAX_POSITIONS_PER_PLAN = 10;

    /// @notice Thrown when the position plan contains no definitions
    error EmptyPositionPlan();
    /// @notice Thrown when the weights across a plan do not sum to `MPS`
    error InvalidAllocationWeights(uint256 totalWeight);
    /// @notice Thrown when the tick bounds are invalid
    /// @param offsetLower The invalid lower tick bound
    /// @param offsetUpper The invalid upper tick bound
    error InvalidTickBounds(int24 offsetLower, int24 offsetUpper);
    /// @notice Thrown when the number of positions exceeds the maximum allowed
    /// @param actual The actual number of positions
    /// @param max The maximum allowed number of positions
    error TooManyPositions(uint24 actual, uint24 max);

    /// @notice Validates that a position plan is non-empty and its weights sum to `MPS`
    /// @param _definitions The weighted position definitions to validate
    function validate(PositionDefinition[] memory _definitions) internal pure {
        if (_definitions.length == 0) revert EmptyPositionPlan();
        if (_definitions.length > MAX_POSITIONS_PER_PLAN) {
            revert TooManyPositions(uint24(_definitions.length), MAX_POSITIONS_PER_PLAN);
        }
        uint256 totalWeight;
        for (uint256 i; i < _definitions.length; i++) {
            if (_definitions[i].offsetLower >= _definitions[i].offsetUpper) {
                revert InvalidTickBounds(_definitions[i].offsetLower, _definitions[i].offsetUpper);
            }
            totalWeight += _definitions[i].weight;
        }
        if (totalWeight != MPS) {
            revert InvalidAllocationWeights(totalWeight);
        }
    }

    /// @notice Solves for the maximum liquidity-per-allocation that fits within both currency budgets
    /// @dev Uses uint256 to avoid overflow; callers must downcast to uint128 before use
    /// @param _currency0Amount The available currency0 budget
    /// @param _currency1Amount The available currency1 budget
    /// @param _weightedAmount0 The weighted currency0 amount for the plan at reference liquidity
    /// @param _weightedAmount1 The weighted currency1 amount for the plan at reference liquidity
    /// @return The maximum liquidity-per-allocation that fits both budgets
    function getLiquidityPerAllocation(
        uint128 _currency0Amount,
        uint128 _currency1Amount,
        uint256 _weightedAmount0,
        uint256 _weightedAmount1
    ) internal pure returns (uint256) {
        if (_weightedAmount0 == 0) {
            return FullMath.mulDiv(_currency1Amount, LIQUIDITY_PRECISION, _weightedAmount1);
        } else if (_weightedAmount1 == 0) {
            return FullMath.mulDiv(_currency0Amount, LIQUIDITY_PRECISION, _weightedAmount0);
        } else {
            return FixedPointMathLib.min(
                FullMath.mulDiv(_currency0Amount, LIQUIDITY_PRECISION, _weightedAmount0),
                FullMath.mulDiv(_currency1Amount, LIQUIDITY_PRECISION, _weightedAmount1)
            );
        }
    }

    /// @notice Converts each definition's relative offsets into absolute tick bounds snapped to `_tickSpacing`
    /// @dev Will clamp to the usable range if the offset exceeds it
    /// @param _definitions The weighted position definitions to resolve
    /// @param _currentTick The current pool tick
    /// @param _tickSpacing The pool tick spacing
    /// @return ticks The absolute tick bounds for each definition
    function _resolveTicks(PositionDefinition[] memory _definitions, int24 _currentTick, int24 _tickSpacing)
        private
        pure
        returns (TickBounds[] memory ticks)
    {
        uint256 len = _definitions.length;
        ticks = new TickBounds[](len);
        int24 minUsable = TickMath.minUsableTick(_tickSpacing);
        int24 maxUsable = TickMath.maxUsableTick(_tickSpacing);
        for (uint256 i; i < len; i++) {
            int24 offsetLower = _definitions[i].offsetLower;
            int24 offsetUpper = _definitions[i].offsetUpper;
            int24 tickLower;
            int24 tickUpper;
            if (offsetLower == TickMath.MIN_TICK && offsetUpper == TickMath.MAX_TICK) {
                tickLower = minUsable;
                tickUpper = maxUsable;
            } else {
                // Widen to int256 to avoid int24 overflow, clamp into the usable range, then snap
                // to tick spacing. `minUsable`/`maxUsable` are spacing-aligned, so floor/ceil stay in range.
                int256 lowerRaw = int256(_currentTick) + int256(offsetLower);
                int256 upperRaw = int256(_currentTick) + int256(offsetUpper);
                tickLower = int24(FixedPointMathLib.clamp(lowerRaw, minUsable, maxUsable)).tickFloor(_tickSpacing);
                tickUpper = int24(FixedPointMathLib.clamp(upperRaw, minUsable, maxUsable)).tickCeil(_tickSpacing);
            }
            ticks[i] = TickBounds({lowerTick: tickLower, upperTick: tickUpper});
        }
    }

    /// @notice Resolves a weighted position plan into concrete positions constrained by the supplied budgets
    /// @dev Callers should invoke `validate` beforehand to ensure weights sum to `MPS`
    ///      and ensure that amounts do not exceed type(int128).max. Invalid or oversized positions are skipped,
    ///      and skipped weights are not redistributed.
    /// @param _definitions The weighted position definitions to resolve
    /// @param _sqrtPriceX96 The pool price used to quote liquidity amounts
    /// @param _tickSpacing The pool tick spacing
    /// @param _currency0Amount The available currency0 budget
    /// @param _currency1Amount The available currency1 budget
    /// @return positions The resolved positions that fit within the supplied budgets
    /// @return remaining0 The unconsumed currency0 budget
    /// @return remaining1 The unconsumed currency1 budget
    function resolve(
        PositionDefinition[] memory _definitions,
        uint160 _sqrtPriceX96,
        int24 _tickSpacing,
        uint128 _currency0Amount,
        uint128 _currency1Amount
    ) internal pure returns (Position[] memory positions, uint128 remaining0, uint128 remaining1) {
        TickBounds[] memory ticks =
            _resolveTicks(_definitions, TickMath.getTickAtSqrtPrice(_sqrtPriceX96), _tickSpacing);

        uint256 liquidityPerAllocation;
        {
            (uint256 weightedAmount0, uint256 weightedAmount1) = _getWeightedAmounts(_definitions, ticks, _sqrtPriceX96);
            if (weightedAmount0 == 0 && weightedAmount1 == 0) {
                return (new Position[](0), _currency0Amount, _currency1Amount);
            }
            liquidityPerAllocation =
                getLiquidityPerAllocation(_currency0Amount, _currency1Amount, weightedAmount0, weightedAmount1);
        }

        positions = new Position[](ticks.length);
        uint256 cnt;
        for (uint256 i; i < ticks.length; i++) {
            (bool valid, Position memory position) =
                _resolvePosition(_definitions[i], ticks[i], _sqrtPriceX96, _tickSpacing, liquidityPerAllocation);
            if (!valid) continue;
            if (position.amount0 > _currency0Amount || position.amount1 > _currency1Amount) continue;

            _currency0Amount -= position.amount0;
            _currency1Amount -= position.amount1;
            positions[cnt++] = position;
        }

        assembly {
            mstore(positions, cnt)
        }

        return (positions, _currency0Amount, _currency1Amount);
    }

    /// @notice Resolves a single weighted definition into a concrete position if it has valid bounds and amounts
    function _resolvePosition(
        PositionDefinition memory _definition,
        TickBounds memory _bounds,
        uint160 _sqrtPriceX96,
        int24 _tickSpacing,
        uint256 _liquidityPerAllocation
    ) private pure returns (bool valid, Position memory position) {
        if (_bounds.lowerTick >= _bounds.upperTick) return (false, position);

        uint256 liquidity = _liquidityPerAllocation * _definition.weight;
        if (liquidity == 0 || liquidity > Pool.tickSpacingToMaxLiquidityPerTick(_tickSpacing)) {
            return (false, position);
        }

        (uint256 amount0, uint256 amount1) = getAmountsForLiquidity(
            _sqrtPriceX96, _bounds.lowerTick, _bounds.upperTick, SafeCastLib.toUint128(liquidity)
        );
        if (amount0 > type(uint128).max || amount1 > type(uint128).max) return (false, position);

        position = Position({
            amount0: SafeCastLib.toUint128(amount0),
            amount1: SafeCastLib.toUint128(amount1),
            tickLower: _bounds.lowerTick,
            tickUpper: _bounds.upperTick,
            liquidity: SafeCastLib.toUint128(liquidity),
            recipient: _definition.recipient
        });
        return (true, position);
    }

    /// @notice Quotes the weighted currency amounts for all valid tick ranges at reference liquidity
    /// @param _definitions The weighted position definitions
    /// @param _ticks The resolved tick bounds for each definition
    /// @param _sqrtPriceX96 The pool price used to quote liquidity amounts
    /// @return weightedAmount0 The total weighted currency0 amount
    /// @return weightedAmount1 The total weighted currency1 amount
    function _getWeightedAmounts(
        PositionDefinition[] memory _definitions,
        TickBounds[] memory _ticks,
        uint160 _sqrtPriceX96
    ) private pure returns (uint256 weightedAmount0, uint256 weightedAmount1) {
        for (uint256 i; i < _ticks.length; i++) {
            TickBounds memory bounds = _ticks[i];
            if (bounds.lowerTick >= bounds.upperTick) continue;
            (uint256 amount0, uint256 amount1) =
                getAmountsForLiquidity(_sqrtPriceX96, bounds.lowerTick, bounds.upperTick, LIQUIDITY_PRECISION);
            weightedAmount0 += amount0 * _definitions[i].weight;
            weightedAmount1 += amount1 * _definitions[i].weight;
        }
    }

    /// @notice Converts concrete positions into a PositionManager plan
    /// @dev Dust left over after minting is returned to `recipient`
    /// @param positions The positions to mint
    /// @param poolKey The pool key for the positions
    /// @param recipient The recipient of leftover dust
    /// @return The encoded action and parameter plan
    function toPlan(Position[] memory positions, PoolKey memory poolKey, address recipient)
        internal
        pure
        returns (Plan memory)
    {
        bytes memory actions = new bytes(positions.length + 3);
        bytes[] memory params = new bytes[](positions.length + 3);
        for (uint256 i; i < positions.length; i++) {
            Position memory position = positions[i];
            actions[i] = bytes1(uint8(Actions.MINT_POSITION));
            params[i] = abi.encode(
                poolKey,
                position.tickLower,
                position.tickUpper,
                position.liquidity,
                position.amount0,
                position.amount1,
                position.recipient,
                bytes("")
            );
        }
        uint256 offset = positions.length;
        actions[offset] = bytes1(uint8(Actions.SETTLE));
        actions[offset + 1] = bytes1(uint8(Actions.SETTLE));
        actions[offset + 2] = bytes1(uint8(Actions.TAKE_PAIR));
        params[offset] = abi.encode(poolKey.currency0, ActionConstants.CONTRACT_BALANCE, false);
        params[offset + 1] = abi.encode(poolKey.currency1, ActionConstants.CONTRACT_BALANCE, false);
        params[offset + 2] = abi.encode(poolKey.currency0, poolKey.currency1, recipient);
        return Plan({actions: actions, params: params});
    }

    /// @notice Quotes token amounts for a liquidity position using v4 core mint math.
    /// @dev Uses SqrtPriceMath with roundUp=true so amount maxes cover PoolManager's required input deltas.
    /// @param _sqrtPriceX96 The current pool price
    /// @param _tickLower The lower tick of the position
    /// @param _tickUpper The upper tick of the position
    /// @param _liquidity The liquidity amount to quote
    /// @return The quoted amount0 and amount1
    function getAmountsForLiquidity(uint160 _sqrtPriceX96, int24 _tickLower, int24 _tickUpper, uint128 _liquidity)
        internal
        pure
        returns (uint256, uint256)
    {
        uint160 sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(_tickLower);
        uint160 sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(_tickUpper);

        if (_sqrtPriceX96 <= sqrtPriceLowerX96) {
            return (SqrtPriceMath.getAmount0Delta(sqrtPriceLowerX96, sqrtPriceUpperX96, _liquidity, true), 0);
        } else if (_sqrtPriceX96 < sqrtPriceUpperX96) {
            return (
                SqrtPriceMath.getAmount0Delta(_sqrtPriceX96, sqrtPriceUpperX96, _liquidity, true),
                SqrtPriceMath.getAmount1Delta(sqrtPriceLowerX96, _sqrtPriceX96, _liquidity, true)
            );
        } else {
            return (0, SqrtPriceMath.getAmount1Delta(sqrtPriceLowerX96, sqrtPriceUpperX96, _liquidity, true));
        }
    }
}
