// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {TickCalculations} from "./TickCalculations.sol";
import {Plan, TickOffsets, Position} from "../types/PositionPlannerTypes.sol";
import {ActionsBuilder} from "./ActionsBuilder.sol";
import {DynamicArray} from "./DynamicArray.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {TickBounds} from "../types/PositionTypes.sol";
/// @title PositionPlanner
/// @notice Converts weighted position configurations into a deterministic PositionManager plan.
library PositionPlanner {
    using TickCalculations for int24;
    using ActionsBuilder for *;
    using DynamicArray for bytes[];

    /// @dev Position allocations are expressed in millionths.
    uint24 internal constant MPS = 1e7;
    /// @dev High-precision liquidity used to quote weighted token consumption.
    uint128 internal constant LIQUIDITY_PRECISION = 1e18;

    error InvalidResolvedTicks(int24 tickLower, int24 tickUpper);

    /// @notice Resolve tick offsets into discrete ticks bounds
    function toTickBounds(TickOffsets[] calldata _params, int24 _currentTick, int24 _tickSpacing)
        internal
        pure
        returns (TickBounds[] memory ticks)
    {
        ticks = new TickBounds[](_params.length);
        for (uint256 i; i < _params.length; i++) {
            TickOffsets memory param = _params[i];
            int24 tickLower;
            int24 tickUpper;
            if (param.offsetLower == TickMath.MIN_TICK && param.offsetUpper == TickMath.MAX_TICK) {
                tickLower = TickMath.minUsableTick(_tickSpacing);
                tickUpper = TickMath.maxUsableTick(_tickSpacing);
            } else {
                tickLower = (_currentTick - param.offsetLower).tickFloor(_tickSpacing);
                tickUpper = (_currentTick + param.offsetUpper).tickCeil(_tickSpacing);
            }

            if (tickLower < TickMath.MIN_TICK || tickUpper > TickMath.MAX_TICK || tickLower >= tickUpper) {
                revert InvalidResolvedTicks(tickLower, tickUpper);
            }
            ticks[i] = TickBounds({lowerTick: tickLower, upperTick: tickUpper});
        }
    }

    /// @notice Computes the total weighted token amounts required per unit of liquidity across all positions.
    /// @dev Used as the first pass of the resolve algorithm to determine how much of each currency
    ///      one unit of allocation consumes, before solving for the max scale factor.
    function getWeightedAmounts(TickBounds[] memory _tickBounds, uint24[] memory _weights, int24 _currentTick)
        internal
        pure
        returns (uint256 weightedAmount0, uint256 weightedAmount1)
    {
        for (uint256 i; i < _tickBounds.length; i++) {
            TickBounds memory bounds = _tickBounds[i];
            (uint256 amount0, uint256 amount1) =
                getAmountsForLiquidity(_currentTick, bounds.lowerTick, bounds.upperTick, LIQUIDITY_PRECISION);
            weightedAmount0 += amount0 * _weights[i];
            weightedAmount1 += amount1 * _weights[i];
        }
    }

    /// @notice Solves for the maximum liquidity-per-allocation that fits within both currency budgets.
    /// @dev Even though liquidity is ultimately required to be within uint128, we use uint256 here to avoid overflows.
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

    /// @notice Creates a deterministic plan for the provided weighted position configurations.
    function resolve(
        TickBounds[] memory _tickBounds,
        uint24[] memory _weights,
        int24 _currentTick,
        uint128 _currency0Amount,
        uint128 _currency1Amount
    ) internal pure returns (Position[] memory, uint128, uint128) {
        require(_tickBounds.length == _weights.length, "Tick bounds and weights must have the same length");

        uint256 liquidityPerAllocation;
        {
            (uint256 weightedAmount0, uint256 weightedAmount1) = getWeightedAmounts(_tickBounds, _weights, _currentTick);
            liquidityPerAllocation =
                getLiquidityPerAllocation(_currency0Amount, _currency1Amount, weightedAmount0, weightedAmount1);
        }

        uint256 len = _tickBounds.length;
        Position[] memory positions = new Position[](len);
        uint256 cnt;
        for (uint256 i; i < len; i++) {
            TickBounds memory bound = _tickBounds[i];
            uint256 liquidity = liquidityPerAllocation * _weights[i];
            if (liquidity == 0 || liquidity > type(uint128).max) {
                continue;
            }

            (uint256 amount0, uint256 amount1) =
                getAmountsForLiquidity(_currentTick, bound.lowerTick, bound.upperTick, SafeCastLib.toUint128(liquidity));

            // Subtract the required amounts from the remaining currency balances.
            assembly {
                _currency0Amount := mul(gt(_currency0Amount, amount0), sub(_currency0Amount, amount0))
                _currency1Amount := mul(gt(_currency1Amount, amount1), sub(_currency1Amount, amount1))
            }
            // Skip if our balance is not sufficient. Accounts for the case where returned amounts are > uint128.max.
            if (_currency0Amount == 0 || _currency1Amount == 0) continue;

            positions[cnt++] = Position({
                amount0: SafeCastLib.toUint128(amount0),
                amount1: SafeCastLib.toUint128(amount1),
                tickLower: bound.lowerTick,
                tickUpper: bound.upperTick,
                liquidity: SafeCastLib.toUint128(liquidity)
            });
        }

        // Truncate the positions array to the number of accepted positions.
        assembly {
            mstore(positions, cnt)
        }

        return (positions, _currency0Amount, _currency1Amount);
    }

    /// @notice Converts an array of concrete positions into a Plan
    function toPlan(
        Position[] memory positions,
        PoolKey memory poolKey,
        address positionRecipient,
        address dustRecipient
    ) internal pure returns (Plan memory) {
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
            .append(abi.encode(poolKey.currency0, poolKey.currency1, dustRecipient));
        return Plan({actions: actions, params: params});
    }

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
