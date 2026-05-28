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
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";

/// @title PositionPlanner
/// @notice Converts weighted position configurations into a deterministic PositionManager plan.
library PositionPlanner {
    using TickCalculations for int24;
    using PositionPlanner for TickBounds;
    using PositionPlanner for Position;

    /// @notice Absolute tick boundaries for a resolved position
    struct TickBounds {
        int24 lowerTick;
        int24 upperTick;
    }

    /// @notice Position allocations are expressed in millionths (1e7 = 100%)
    uint24 internal constant MPS = 1e7;
    /// @notice The maximum number of positions that can be included in a plan to prevent OOG
    uint24 public constant MAX_POSITIONS_PER_PLAN = 10;

    /// @notice Thrown when the weights across a plan exceed `MPS`
    error InvalidAllocationWeights(uint256 totalWeight);
    /// @notice Thrown when an individual position definition has zero allocation weight
    /// @param index The index of the invalid position definition
    error ZeroPositionWeight(uint256 index);
    /// @notice Thrown when the tick bounds are invalid
    /// @param offsetLower The invalid lower tick bound
    /// @param offsetUpper The invalid upper tick bound
    error InvalidTickBounds(int24 offsetLower, int24 offsetUpper);
    /// @notice Thrown when the number of positions exceeds the maximum allowed
    /// @param actual The actual number of positions
    /// @param max The maximum allowed number of positions
    error TooManyPositions(uint24 actual, uint24 max);

    /// @notice Validates that position definitions are correct
    /// @dev Reverts if the number of definitions exceeds the maximum allowed,
    ///      if tick offsets are out of order, or if the total weight exceeds `MPS`
    /// @param _definitions the position definitions
    function validate(PositionDefinition[] memory _definitions) internal pure {
        if (_definitions.length > MAX_POSITIONS_PER_PLAN) {
            revert TooManyPositions(uint24(_definitions.length), MAX_POSITIONS_PER_PLAN);
        }
        uint256 totalWeight;
        for (uint256 i; i < _definitions.length; i++) {
            if (_definitions[i].offsetLower >= _definitions[i].offsetUpper) {
                revert InvalidTickBounds(_definitions[i].offsetLower, _definitions[i].offsetUpper);
            }
            if (_definitions[i].weight == 0) revert ZeroPositionWeight(i);
            totalWeight += _definitions[i].weight;
        }
        if (totalWeight > MPS) {
            revert InvalidAllocationWeights(totalWeight);
        }
    }

    /// @notice Converts each definition's relative offsets into absolute tick bounds snapped to `_tickSpacing`
    /// @notice MAY return invalid tick ranges which MUST be checked by the caller
    /// @param _definitions The weighted position definitions to resolve
    /// @param _currentTick The current pool tick
    /// @param _tickSpacing The pool tick spacing
    /// @return ticks The absolute tick bounds for each definition
    function resolveTicks(PositionDefinition[] memory _definitions, int24 _currentTick, int24 _tickSpacing)
        internal
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
        uint256 _currency0Amount,
        uint256 _currency1Amount
    ) internal pure returns (Position[] memory positions, uint256, uint256) {
        TickBounds[] memory ticks = resolveTicks(_definitions, TickMath.getTickAtSqrtPrice(_sqrtPriceX96), _tickSpacing);
        positions = new Position[](ticks.length + 1);

        uint24 remainingPercentage = MPS;
        uint24 cnt = 0;
        for (uint256 i; i < ticks.length; i++) {
            uint24 weight = _definitions[i].weight;
            // Get the position's share of the remaining currency budget (defined in MPS terms)
            Position memory position = ticks[i].resolvePosition(
                _sqrtPriceX96,
                Pool.tickSpacingToMaxLiquidityPerTick(_tickSpacing),
                _currency0Amount * weight / remainingPercentage,
                _currency1Amount * weight / remainingPercentage
            );
            remainingPercentage -= weight;
            // Empty positions are skipped but their weights are subtracted from the remaining percentage
            // such that future positions will consume a larger proportion of the remaining budget
            if (!position.isEmpty()) {
                _currency0Amount -= position.amount0;
                _currency1Amount -= position.amount1;
                positions[cnt++] = position;
            }
        }

        // Create the fallback full range position with remaining budget
        {
            TickBounds memory fullRangeBounds = TickBounds({
                lowerTick: TickMath.minUsableTick(_tickSpacing), upperTick: TickMath.maxUsableTick(_tickSpacing)
            });
            Position memory position = fullRangeBounds.resolvePosition(
                _sqrtPriceX96, Pool.tickSpacingToMaxLiquidityPerTick(_tickSpacing), _currency0Amount, _currency1Amount
            );
            if (!position.isEmpty()) {
                _currency0Amount -= position.amount0;
                _currency1Amount -= position.amount1;
                positions[cnt++] = position;
            }
        }

        // truncate the positions array to the actual created number of positions
        assembly {
            mstore(positions, cnt)
        }

        return (positions, _currency0Amount, _currency1Amount);
    }

    /// @notice Returns true if tick bounds are correctly ordered
    function areValid(TickBounds memory _bounds) internal pure returns (bool) {
        return _bounds.lowerTick < _bounds.upperTick;
    }

    /// @notice Returns true if a position is empty
    function isEmpty(Position memory _position) internal pure returns (bool) {
        return _position.liquidity == 0;
    }

    /// @notice Resolves tick bounds into a position, allocating up to the provided budgets
    /// @dev The actual amounts required for the computed liquidity will be less than or equal to the budget
    function resolvePosition(
        TickBounds memory _bounds,
        uint160 _sqrtPriceX96,
        uint128 _maxLiquidityPerTick,
        uint256 _currency0Budget,
        uint256 _currency1Budget
    ) internal pure returns (Position memory position) {
        // Skip invalid tick bounds
        if (!_bounds.areValid()) return position;

        uint256 liquidity = _getLiquidityForAmounts(
            _sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(_bounds.lowerTick),
            TickMath.getSqrtPriceAtTick(_bounds.upperTick),
            _currency0Budget,
            _currency1Budget
        );
        // Skip positions that are too large or have no liquidity
        if (liquidity > _maxLiquidityPerTick || liquidity == 0) return position;

        // amounts will be less than or equal to the budget amounts
        (uint256 amount0, uint256 amount1) =
            _getAmountsForLiquidity(_sqrtPriceX96, _bounds.lowerTick, _bounds.upperTick, uint128(liquidity));

        return Position({
            amount0: amount0,
            amount1: amount1,
            tickLower: _bounds.lowerTick,
            tickUpper: _bounds.upperTick,
            liquidity: liquidity
        });
    }

    /// @notice Converts concrete positions into a PositionManager plan
    /// @dev Dust left over after minting is returned to `positionRecipient`
    /// @param positions The positions to mint
    /// @param poolKey The pool key for the positions
    /// @param positionRecipient The recipient of minted positions and leftover dust
    /// @return The encoded action and parameter plan
    function toPlan(Position[] memory positions, PoolKey memory poolKey, address positionRecipient)
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
                positionRecipient,
                bytes("")
            );
        }
        uint256 offset = positions.length;
        actions[offset] = bytes1(uint8(Actions.SETTLE));
        actions[offset + 1] = bytes1(uint8(Actions.SETTLE));
        actions[offset + 2] = bytes1(uint8(Actions.TAKE_PAIR));
        params[offset] = abi.encode(poolKey.currency0, ActionConstants.CONTRACT_BALANCE, false);
        params[offset + 1] = abi.encode(poolKey.currency1, ActionConstants.CONTRACT_BALANCE, false);
        params[offset + 2] = abi.encode(poolKey.currency0, poolKey.currency1, positionRecipient);
        return Plan({actions: actions, params: params});
    }

    /// @notice Implementation of `LiquidityAmounts.getLiquidityForAmount0` without the downcast to uint128
    function _getLiquidityForAmount0(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint256 amount0)
        private
        pure
        returns (uint256 liquidity)
    {
        unchecked {
            if (sqrtPriceAX96 > sqrtPriceBX96) (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
            uint256 intermediate = FullMath.mulDiv(sqrtPriceAX96, sqrtPriceBX96, FixedPoint96.Q96);
            return FullMath.mulDiv(amount0, intermediate, sqrtPriceBX96 - sqrtPriceAX96);
        }
    }

    /// @notice Implementation of `LiquidityAmounts.getLiquidityForAmount1` without the downcast to uint128
    function _getLiquidityForAmount1(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint256 amount1)
        private
        pure
        returns (uint256 liquidity)
    {
        unchecked {
            if (sqrtPriceAX96 > sqrtPriceBX96) (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
            return FullMath.mulDiv(amount1, FixedPoint96.Q96, sqrtPriceBX96 - sqrtPriceAX96);
        }
    }

    /// @notice Implementation of `LiquidityAmounts.getLiquidityForAmounts` without the downcast to uint128
    function _getLiquidityForAmounts(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint256 amount0,
        uint256 amount1
    ) private pure returns (uint256 liquidity) {
        if (sqrtPriceAX96 > sqrtPriceBX96) {
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        }

        if (sqrtPriceX96 <= sqrtPriceAX96) {
            liquidity = _getLiquidityForAmount0(sqrtPriceAX96, sqrtPriceBX96, amount0);
        } else if (sqrtPriceX96 < sqrtPriceBX96) {
            uint256 liquidity0 = _getLiquidityForAmount0(sqrtPriceX96, sqrtPriceBX96, amount0);
            uint256 liquidity1 = _getLiquidityForAmount1(sqrtPriceAX96, sqrtPriceX96, amount1);

            liquidity = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
        } else {
            liquidity = _getLiquidityForAmount1(sqrtPriceAX96, sqrtPriceBX96, amount1);
        }
    }

    /// @notice Quotes token amounts for a liquidity position using v4 core mint math.
    /// @dev Uses SqrtPriceMath with roundUp=true so amount maxes cover PoolManager's required input deltas.
    /// @param _sqrtPriceX96 The current pool price
    /// @param _tickLower The lower tick of the position
    /// @param _tickUpper The upper tick of the position
    /// @param _liquidity The liquidity amount to quote
    /// @return The quoted amount0 and amount1
    function _getAmountsForLiquidity(uint160 _sqrtPriceX96, int24 _tickLower, int24 _tickUpper, uint128 _liquidity)
        private
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
