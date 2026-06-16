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
import {Plan, Position, PositionDefinition, CurrencyAmounts} from "../types/PositionPlannerTypes.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";

/// @title PositionPlanner
/// @notice Converts weighted position configurations into a deterministic PositionManager plan.
library PositionPlanner {
    using TickCalculations for int24;
    using PositionPlanner for *;

    /// @notice Absolute tick boundaries for a resolved position
    struct TickBounds {
        int24 lowerTick;
        int24 upperTick;
    }

    /// @notice Position allocations are expressed in millionths (1e7 = 100%)
    uint24 internal constant MPS = 1e7;
    /// @notice The maximum number of additional positions which can be defined in addition
    ///         to the implicit full range fallback (10 + 1 = 11 maximum positions possible)
    uint24 public constant MAX_ADDITIONAL_POSITIONS_PER_PLAN = 10;

    /// @notice Thrown when the weights across a plan exceed `MPS`
    error InvalidAllocationWeights(uint256 totalWeight);
    /// @notice Thrown when an individual position definition has zero allocation weight
    /// @param index The index of the invalid position definition
    error ZeroPositionWeight(uint256 index);
    /// @notice Thrown when the tick bounds are invalid
    /// @param offsetLower The invalid lower tick bound
    /// @param offsetUpper The invalid upper tick bound
    error InvalidTickBounds(int24 offsetLower, int24 offsetUpper);
    /// @notice Thrown when a position's overridePositionRecipient is a reserved address (address(1) or address(2))
    /// @param recipient The invalid position recipient
    error InvalidPositionRecipient(address recipient);
    /// @notice Thrown when the number of positions exceeds the maximum allowed
    /// @param actual The actual number of positions
    /// @param max The maximum allowed number of positions
    error TooManyPositions(uint24 actual, uint24 max);

    /// @notice Validates that position definitions are correct
    /// @dev Reverts if the number of definitions exceeds the maximum allowed,
    ///      if tick offsets are out of order, or if the total weight exceeds `MPS`
    /// @param _definitions the position definitions
    function validate(PositionDefinition[] memory _definitions) internal pure {
        if (_definitions.length > MAX_ADDITIONAL_POSITIONS_PER_PLAN) {
            revert TooManyPositions(uint24(_definitions.length), MAX_ADDITIONAL_POSITIONS_PER_PLAN);
        }
        uint256 totalWeight;
        for (uint256 i; i < _definitions.length; i++) {
            PositionDefinition memory definition = _definitions[i];
            if (definition.offsetLower >= definition.offsetUpper) {
                revert InvalidTickBounds(definition.offsetLower, definition.offsetUpper);
            }
            if (definition.weight == 0) revert ZeroPositionWeight(i);
            // overridePositionRecipient is optional: address(0) means "use the default positionRecipient".
            // When specified, it cannot be a PositionManager reserved sentinel (address(1) or address(2)).
            address overrideRecipient = definition.overridePositionRecipient;
            if (overrideRecipient != address(0) && uint160(overrideRecipient) <= uint160(ActionConstants.ADDRESS_THIS))
            {
                revert InvalidPositionRecipient(overrideRecipient);
            }
            totalWeight += definition.weight;
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
                // Add offsets, clamp to the valid min/max range, then snap to tick spacing.
                tickLower = int24(
                        FixedPointMathLib.clamp(int256(_currentTick) + int256(offsetLower), minUsable, maxUsable)
                    ).tickFloor(_tickSpacing);
                tickUpper = int24(
                        FixedPointMathLib.clamp(int256(_currentTick) + int256(offsetUpper), minUsable, maxUsable)
                    ).tickCeil(_tickSpacing);
            }
            ticks[i] = TickBounds({lowerTick: tickLower, upperTick: tickUpper});
        }
    }

    /// @notice Resolves a weighted position plan into concrete positions constrained by the supplied budgets
    /// @param _definitions The weighted position definitions to resolve
    /// @param _sqrtPriceX96 The pool price used to quote liquidity amounts
    /// @param _tickSpacing The pool tick spacing
    /// @param _currencyAmounts The available currency0 and currency1 budgets
    /// @param _positionRecipient The default recipient for minted positions; used for the implicit full-range
    ///        fallback position and for any definition without an overridePositionRecipient
    /// @return positions The resolved positions that fit within the supplied budgets
    /// @return remainingAmounts The unconsumed currency0 and currency1 budgets
    function resolve(
        PositionDefinition[] memory _definitions,
        uint160 _sqrtPriceX96,
        int24 _tickSpacing,
        CurrencyAmounts memory _currencyAmounts,
        address _positionRecipient
    ) internal pure returns (Position[] memory positions, CurrencyAmounts memory remainingAmounts) {
        TickBounds[] memory ticks = resolveTicks(_definitions, TickMath.getTickAtSqrtPrice(_sqrtPriceX96), _tickSpacing);
        positions = new Position[](ticks.length + 1);

        // V4 enforces maxLiquidityPerTick against that tick's liquidityGross, which only accumulates at a
        // position's two boundary ticks. Each candidate is therefore capped by the liquidity remaining at its tighter
        // boundary given the positions already created (see _remainingLiquidity). On a new pool this keeps every tick's gross
        // within the cap while letting positions that share no boundary each use the full max liquidity per tick.
        uint128 maxLiquidityPerTick = Pool.tickSpacingToMaxLiquidityPerTick(_tickSpacing);
        remainingAmounts = _currencyAmounts;
        uint24 cnt = 0;
        // Definitions are processed in order: each created position consumes a portion of the budget
        // Reordering the same definitions can therefore result in a different set of positions being created
        for (uint256 i; i < ticks.length; i++) {
            uint24 weight = _definitions[i].weight;
            address overrideRecipient = _definitions[i].overridePositionRecipient;
            // Cap to the remaining liquidity allowed at this candidate's boundaries by the positions already created.
            Position memory position = ticks[i].resolvePosition(
                _sqrtPriceX96,
                _remainingLiquidity(positions, cnt, maxLiquidityPerTick, ticks[i].lowerTick, ticks[i].upperTick),
                _currencyAmounts.applyWeight(weight),
                overrideRecipient == address(0) ? _positionRecipient : overrideRecipient
            );
            // Failed positions are skipped and their allocations will be used in a full range position.
            if (!position.isEmpty()) {
                remainingAmounts = remainingAmounts.sub(position.amount0, position.amount1);
                positions[cnt++] = position;
            }
        }

        // Create a full range position with all remaining budget
        {
            int24 fullLower = TickMath.minUsableTick(_tickSpacing);
            int24 fullUpper = TickMath.maxUsableTick(_tickSpacing);
            Position memory position = PositionPlanner.resolvePosition(
                TickBounds({lowerTick: fullLower, upperTick: fullUpper}),
                _sqrtPriceX96,
                _remainingLiquidity(positions, cnt, maxLiquidityPerTick, fullLower, fullUpper),
                remainingAmounts,
                _positionRecipient // the full range position always uses the default position recipient
            );
            if (!position.isEmpty()) {
                remainingAmounts = remainingAmounts.sub(position.amount0, position.amount1);
                positions[cnt++] = position;
            }
        }

        // truncate the positions array to the actual created number of positions
        assembly {
            mstore(positions, cnt)
        }

        return (positions, remainingAmounts);
    }

    /// @notice Creates a position based on the parameters. Prevents zero liquidity and otherwise invalid positions.
    /// @dev The actual amounts required for the computed liquidity will be less than or equal to the initial amounts
    /// @param _bounds The TickBounds to resolve
    /// @param _sqrtPriceX96 The initial sqrt price of the pool
    /// @param _maxLiquidity The maximum liquidity which can be created
    /// @param _currencyAmounts The maximum currency amounts available for use
    /// @param _recipient The recipient of the position
    /// @return position The created position, or an empty struct if the tick bounds are invalid or liquidity is zero
    function resolvePosition(
        TickBounds memory _bounds,
        uint160 _sqrtPriceX96,
        uint128 _maxLiquidity,
        CurrencyAmounts memory _currencyAmounts,
        address _recipient
    ) internal pure returns (Position memory position) {
        if (!_bounds.isValid()) return position;

        uint256 liquidity = _getLiquidityForAmounts(
            _sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(_bounds.lowerTick),
            TickMath.getSqrtPriceAtTick(_bounds.upperTick),
            _currencyAmounts.amount0,
            _currencyAmounts.amount1
        );
        if (liquidity == 0) return position;

        liquidity = liquidity > _maxLiquidity ? _maxLiquidity : liquidity;

        (uint256 amount0, uint256 amount1) =
            _getAmountsForLiquidity(_sqrtPriceX96, _bounds.lowerTick, _bounds.upperTick, uint128(liquidity));

        return Position({
            amount0: amount0,
            amount1: amount1,
            tickLower: _bounds.lowerTick,
            tickUpper: _bounds.upperTick,
            liquidity: liquidity,
            recipient: _recipient
        });
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

    /// @notice Returns true if TickBounds are correctly ordered
    function isValid(TickBounds memory _bounds) internal pure returns (bool) {
        return _bounds.lowerTick < _bounds.upperTick;
    }

    /// @notice Returns true if a Position is empty
    function isEmpty(Position memory _position) internal pure returns (bool) {
        return _position.liquidity == 0;
    }

    /// @notice Applies a weight to a CurrencyAmounts struct
    /// @return the result in CurrencyAmounts
    function applyWeight(CurrencyAmounts memory _amounts, uint24 _weight)
        internal
        pure
        returns (CurrencyAmounts memory)
    {
        return CurrencyAmounts({amount0: _amounts.amount0 * _weight / MPS, amount1: _amounts.amount1 * _weight / MPS});
    }

    /// @notice Checked subtraction of amounts from a CurrencyAmounts struct
    /// @return the result in CurrencyAmounts
    function sub(CurrencyAmounts memory _amounts, uint256 _amount0, uint256 _amount1)
        internal
        pure
        returns (CurrencyAmounts memory)
    {
        return CurrencyAmounts({amount0: _amounts.amount0 - _amount0, amount1: _amounts.amount1 - _amount1});
    }

    /// @notice Remaining per-tick liquidity for a candidate position's boundaries
    /// @dev liquidityGross is contributed by a position only at its tickLower and tickUpper, so two positions only
    ///      compete for the cap when they share an exact boundary. This sums the gross already contributed by created
    ///      positions at each of the candidate's boundary ticks and returns the cap minus the larger of the two.
    ///      Capping the candidate to this value keeps both of its boundary ticks within `_maxLiquidityPerTick`. By
    ///      induction every created position keeps its boundaries within the cap, so `maxGross <= _maxLiquidityPerTick`
    ///      always holds and the subtraction cannot underflow. O(n) per call, O(n^2) over the at most 11 positions.
    /// @param _positions The positions created so far
    /// @param _count The number of created positions in `_positions`
    /// @param _maxLiquidityPerTick The per-tick max liquidity for the pool's tick spacing
    /// @param _lowerTick The candidate's lower boundary tick
    /// @param _upperTick The candidate's upper boundary tick
    /// @return The liquidity remaining available to the candidate
    function _remainingLiquidity(
        Position[] memory _positions,
        uint24 _count,
        uint128 _maxLiquidityPerTick,
        int24 _lowerTick,
        int24 _upperTick
    ) private pure returns (uint128) {
        uint128 grossLower;
        uint128 grossUpper;
        for (uint256 j; j < _count; j++) {
            uint128 liq = uint128(_positions[j].liquidity);
            int24 lower = _positions[j].tickLower;
            int24 upper = _positions[j].tickUpper;
            if (lower == _lowerTick || upper == _lowerTick) grossLower += liq;
            if (lower == _upperTick || upper == _upperTick) grossUpper += liq;
        }
        uint128 maxGross = grossLower > grossUpper ? grossLower : grossUpper;
        return _maxLiquidityPerTick - maxGross;
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
