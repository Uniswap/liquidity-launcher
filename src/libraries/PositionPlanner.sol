// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {TickCalculations} from "./TickCalculations.sol";
import {Plan, Position, PositionDefinition} from "../types/PositionPlannerTypes.sol";
import {TickBounds} from "../types/PositionTypes.sol";
import {ActionsBuilder} from "./ActionsBuilder.sol";
import {DynamicArray} from "./DynamicArray.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @title PositionPlanner
/// @notice Converts weighted position configurations into a deterministic PositionManager plan.
library PositionPlanner {
    using TickCalculations for int24;
    using ActionsBuilder for *;
    using DynamicArray for bytes[];

    /// @notice Position allocations are expressed in millionths (1e7 = 100%)
    uint24 internal constant MPS = 1e7;
    /// @notice Reference liquidity used to quote weighted token consumption
    uint128 internal constant LIQUIDITY_PRECISION = 1e18;

    /// @notice Thrown when the position plan contains no definitions
    error EmptyPositionPlan();
    /// @notice Thrown when the weights across a plan do not sum to `MPS`
    error InvalidAllocationWeights(uint24 totalWeight);

    /// @notice Validates that a position plan is non-empty and its weights sum to `MPS`
    function validate(PositionDefinition[] memory _definitions) internal pure {
        if (_definitions.length == 0) revert EmptyPositionPlan();
        uint256 totalWeight;
        for (uint256 i; i < _definitions.length; i++) {
            totalWeight += _definitions[i].weight;
        }
        if (totalWeight != MPS) {
            revert InvalidAllocationWeights(uint24(totalWeight));
        }
    }

    /// @notice Solves for the maximum liquidity-per-allocation that fits within both currency budgets
    /// @dev Uses uint256 to avoid overflow; callers must downcast to uint128 before use
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
    function resolve(
        PositionDefinition[] memory _definitions,
        int24 _currentTick,
        int24 _tickSpacing,
        uint128 _currency0Amount,
        uint128 _currency1Amount
    ) internal pure returns (Position[] memory positions, uint128 remaining0, uint128 remaining1) {
        TickBounds[] memory ticks = _resolveTicks(_definitions, _currentTick, _tickSpacing);

        uint256 liquidityPerAllocation;
        {
            uint256 weightedAmount0;
            uint256 weightedAmount1;
            for (uint256 i; i < ticks.length; i++) {
                TickBounds memory bounds = ticks[i];
                if (bounds.lowerTick >= bounds.upperTick) continue;
                (uint256 amount0, uint256 amount1) =
                    getAmountsForLiquidity(_currentTick, bounds.lowerTick, bounds.upperTick, LIQUIDITY_PRECISION);
                weightedAmount0 += amount0 * _definitions[i].weight;
                weightedAmount1 += amount1 * _definitions[i].weight;
            }
            if (weightedAmount0 == 0 && weightedAmount1 == 0) {
                return (new Position[](0), _currency0Amount, _currency1Amount);
            }
            liquidityPerAllocation =
                getLiquidityPerAllocation(_currency0Amount, _currency1Amount, weightedAmount0, weightedAmount1);
        }

        positions = new Position[](ticks.length);
        uint256 cnt;
        for (uint256 i; i < ticks.length; i++) {
            TickBounds memory bounds = ticks[i];
            if (bounds.lowerTick >= bounds.upperTick) continue;
            uint256 liquidity = liquidityPerAllocation * _definitions[i].weight;
            if (liquidity == 0 || liquidity > type(uint128).max) {
                continue;
            }

            (uint256 amount0, uint256 amount1) = getAmountsForLiquidity(
                _currentTick, bounds.lowerTick, bounds.upperTick, SafeCastLib.toUint128(liquidity)
            );

            if (amount0 > _currency0Amount || amount1 > _currency1Amount) continue;

            _currency0Amount -= uint128(amount0);
            _currency1Amount -= uint128(amount1);

            positions[cnt++] = Position({
                amount0: SafeCastLib.toUint128(amount0),
                amount1: SafeCastLib.toUint128(amount1),
                tickLower: bounds.lowerTick,
                tickUpper: bounds.upperTick,
                liquidity: SafeCastLib.toUint128(liquidity)
            });
        }

        assembly {
            mstore(positions, cnt)
        }

        return (positions, _currency0Amount, _currency1Amount);
    }

    /// @notice Converts concrete positions into a PositionManager plan
    /// @dev Dust left over after minting is returned to `positionRecipient`
    function toPlan(Position[] memory positions, PoolKey memory poolKey, address positionRecipient)
        internal
        pure
        returns (Plan memory)
    {
        bytes memory actions = ActionsBuilder.init();
        bytes[] memory params = DynamicArray.init();
        for (uint256 i; i < positions.length; i++) {
            Position memory position = positions[i];
            actions = actions.addMint();
            params = params.append(
                abi.encode(
                    poolKey,
                    position.tickLower,
                    position.tickUpper,
                    position.liquidity,
                    position.amount0,
                    position.amount1,
                    positionRecipient,
                    bytes("")
                )
            );
        }
        actions = actions.addSettle().addSettle().addTakePair();
        params = params.append(abi.encode(poolKey.currency0, ActionConstants.CONTRACT_BALANCE, false))
            .append(abi.encode(poolKey.currency1, ActionConstants.CONTRACT_BALANCE, false))
            .append(abi.encode(poolKey.currency0, poolKey.currency1, positionRecipient));
        return Plan({actions: actions, params: params});
    }

    /// @notice Wrapper around `LiquidityAmounts.getAmountsForLiquidity` which converts ticks into sqrt prices
    function getAmountsForLiquidity(int24 _currentTick, int24 _tickLower, int24 _tickUpper, uint128 _liquidity)
        internal
        pure
        returns (uint256, uint256)
    {
        return LiquidityAmounts.getAmountsForLiquidity(
            TickMath.getSqrtPriceAtTick(_currentTick),
            TickMath.getSqrtPriceAtTick(_tickLower),
            TickMath.getSqrtPriceAtTick(_tickUpper),
            _liquidity
        );
    }
}
