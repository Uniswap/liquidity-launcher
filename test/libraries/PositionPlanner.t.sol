// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {PositionPlanner} from "src/libraries/PositionPlanner.sol";
import {Plan, RelativeTickBounds, Position} from "src/types/PositionPlannerTypes.sol";
import {TickBounds} from "src/types/PositionTypes.sol";

contract MockPositionPlanner {
    function parseTicks(RelativeTickBounds[] calldata params, int24 currentTick, int24 tickSpacing)
        external
        pure
        returns (TickBounds[] memory)
    {
        return PositionPlanner.parseTicks(params, currentTick, tickSpacing);
    }

    function validateWeights(uint24[] calldata weights) external pure {
        PositionPlanner.validateWeights(weights);
    }

    function resolve(
        TickBounds[] memory tickBounds,
        uint24[] memory weights,
        int24 currentTick,
        uint128 currency0Amount,
        uint128 currency1Amount
    ) external pure returns (Position[] memory, uint128, uint128) {
        return PositionPlanner.resolve(tickBounds, weights, currentTick, currency0Amount, currency1Amount);
    }

    function toPlan(
        Position[] memory positions,
        PoolKey memory poolKey,
        address positionRecipient,
        address dustRecipient
    ) external pure returns (Plan memory) {
        return PositionPlanner.toPlan(positions, poolKey, positionRecipient, dustRecipient);
    }
}

contract PositionPlannerTest is Test {
    MockPositionPlanner public mockPositionPlanner;

    function assertMintParam(bytes memory param, int24 tickSpacing, Position memory position, address expectedRecipient)
        public
        pure
    {
        (
            PoolKey memory poolKey,
            int24 tickLower,
            int24 tickUpper,
            uint256 liquidity,
            uint128 amount0,
            uint128 amount1,
            address recipient,
        ) = abi.decode(param, (PoolKey, int24, int24, uint256, uint128, uint128, address, bytes));
        assertEq(poolKey.tickSpacing, tickSpacing);
        assertEq(tickLower, position.tickLower);
        assertEq(tickUpper, position.tickUpper);
        assertEq(liquidity, position.liquidity);
        assertEq(amount0, position.amount0);
        assertEq(amount1, position.amount1);
        assertEq(recipient, expectedRecipient);
    }

    function assertTakePairParam(
        bytes memory param,
        Currency expectedCurrency0,
        Currency expectedCurrency1,
        address expectedRecipient
    ) public pure {
        (Currency currency0, Currency currency1, address recipient) = abi.decode(param, (Currency, Currency, address));
        assertEq(Currency.unwrap(currency0), Currency.unwrap(expectedCurrency0));
        assertEq(Currency.unwrap(currency1), Currency.unwrap(expectedCurrency1));
        assertEq(recipient, expectedRecipient);
    }

    function setUp() public {
        mockPositionPlanner = new MockPositionPlanner();
    }

    // --- parseTicks ---

    function test_parseTicks_revertsOnInvalidResolvedTicks() public {
        RelativeTickBounds[] memory defs = new RelativeTickBounds[](1);
        defs[0] = RelativeTickBounds({offsetLower: 0, offsetUpper: 0});

        vm.expectRevert(abi.encodeWithSelector(PositionPlanner.InvalidResolvedTicks.selector, int24(0), int24(0)));
        mockPositionPlanner.parseTicks(defs, 0, 10);
    }

    function test_fuzz_parseTicks_fullRangeSentinel(int24 currentTick, int24 tickSpacing) public view {
        tickSpacing = int24(bound(tickSpacing, TickMath.MIN_TICK_SPACING, TickMath.MAX_TICK_SPACING));
        currentTick = int24(bound(currentTick, TickMath.MIN_TICK + 1, TickMath.MAX_TICK - 1));

        RelativeTickBounds[] memory defs = new RelativeTickBounds[](1);
        defs[0] = RelativeTickBounds({offsetLower: TickMath.MIN_TICK, offsetUpper: TickMath.MAX_TICK});

        TickBounds[] memory ticks = mockPositionPlanner.parseTicks(defs, currentTick, tickSpacing);

        assertEq(ticks[0].lowerTick, TickMath.minUsableTick(tickSpacing));
        assertEq(ticks[0].upperTick, TickMath.maxUsableTick(tickSpacing));
    }

    function test_fuzz_parseTicks_relativeOffsets(
        int24 currentTick,
        int24 tickSpacing,
        int24 offsetLower,
        int24 offsetUpper
    ) public view {
        tickSpacing = int24(bound(tickSpacing, TickMath.MIN_TICK_SPACING, TickMath.MAX_TICK_SPACING));
        currentTick = int24(bound(currentTick, TickMath.MIN_TICK / 2, TickMath.MAX_TICK / 2));
        offsetLower = int24(bound(offsetLower, 0, 10000));
        offsetUpper = int24(bound(offsetUpper, 0, 10000));

        RelativeTickBounds[] memory defs = new RelativeTickBounds[](1);
        defs[0] = RelativeTickBounds({offsetLower: offsetLower, offsetUpper: offsetUpper});

        try mockPositionPlanner.parseTicks(defs, currentTick, tickSpacing) returns (TickBounds[] memory ticks) {
            assertLt(ticks[0].lowerTick, ticks[0].upperTick);
            assertEq(ticks[0].lowerTick % tickSpacing, 0);
            assertEq(ticks[0].upperTick % tickSpacing, 0);
            assertGe(ticks[0].lowerTick, TickMath.MIN_TICK);
            assertLe(ticks[0].upperTick, TickMath.MAX_TICK);
        } catch {}
    }

    // --- validateWeights ---

    function test_validateWeights_revertsOnInvalidWeights() public {
        uint24[] memory weights = new uint24[](1);
        weights[0] = 5e6;

        vm.expectRevert(abi.encodeWithSelector(PositionPlanner.InvalidAllocationWeights.selector, uint24(5e6)));
        mockPositionPlanner.validateWeights(weights);
    }

    function test_fuzz_validateWeights(uint24 weight0) public view {
        weight0 = uint24(bound(weight0, 1, 1e7 - 1));

        uint24[] memory weights = new uint24[](2);
        weights[0] = weight0;
        weights[1] = uint24(1e7) - weight0;

        mockPositionPlanner.validateWeights(weights);
    }

    // --- resolve ---

    function test_resolve_revertsOnMismatchedLengths() public {
        TickBounds[] memory tickBounds = new TickBounds[](2);
        tickBounds[0] = TickBounds({lowerTick: -10, upperTick: 10});
        tickBounds[1] = TickBounds({lowerTick: -20, upperTick: 20});

        uint24[] memory weights = new uint24[](1);
        weights[0] = 1e7;

        vm.expectRevert("Tick bounds and weights must have the same length");
        mockPositionPlanner.resolve(tickBounds, weights, 0, 100e18, 100e18);
    }

    function test_fuzz_resolve(int24 currentTick, int24 tickSpacing, uint128 currency0Amount, uint128 currency1Amount)
        public
        view
    {
        vm.assume(uint256(currency0Amount) + uint256(currency1Amount) < type(uint128).max);
        tickSpacing = int24(bound(tickSpacing, TickMath.MIN_TICK_SPACING, TickMath.MAX_TICK_SPACING));
        currentTick = int24(bound(currentTick, TickMath.MIN_TICK + 1, TickMath.MAX_TICK - 1));

        RelativeTickBounds[] memory defs = new RelativeTickBounds[](1);
        defs[0] = RelativeTickBounds({offsetLower: TickMath.MIN_TICK, offsetUpper: TickMath.MAX_TICK});

        TickBounds[] memory tickBounds = mockPositionPlanner.parseTicks(defs, currentTick, tickSpacing);

        uint24[] memory weights = new uint24[](1);
        weights[0] = 1e7;

        (, uint128 remaining0, uint128 remaining1) =
            mockPositionPlanner.resolve(tickBounds, weights, currentTick, currency0Amount, currency1Amount);

        assertLe(remaining0, currency0Amount);
        assertLe(remaining1, currency1Amount);
    }

    // --- toPlan (resolve → toPlan) ---

    function test_toPlan_buildsFixedSharePlan() public view {
        PoolKey memory poolKey = _poolKey(10);
        int24 currentTick = 0;
        int24 tickSpacing = 10;
        uint128 currency0Amount = 100e18;
        uint128 currency1Amount = 100e18;

        RelativeTickBounds[] memory defs = new RelativeTickBounds[](2);
        defs[0] = RelativeTickBounds({offsetLower: TickMath.MIN_TICK, offsetUpper: TickMath.MAX_TICK});
        defs[1] = RelativeTickBounds({offsetLower: 20, offsetUpper: 20});

        TickBounds[] memory tickBounds = mockPositionPlanner.parseTicks(defs, currentTick, tickSpacing);

        uint24[] memory weights = new uint24[](2);
        weights[0] = 5e6;
        weights[1] = 5e6;

        (Position[] memory positions, uint128 remaining0, uint128 remaining1) =
            mockPositionPlanner.resolve(tickBounds, weights, currentTick, currency0Amount, currency1Amount);

        Plan memory result = mockPositionPlanner.toPlan(positions, poolKey, address(3), address(4));

        assertEq(
            result.actions,
            abi.encodePacked(
                uint8(Actions.MINT_POSITION),
                uint8(Actions.MINT_POSITION),
                uint8(Actions.SETTLE),
                uint8(Actions.SETTLE),
                uint8(Actions.TAKE_PAIR)
            )
        );
        assertEq(result.params.length, 5);
        assertLe(remaining0, currency0Amount);
        assertLe(remaining1, currency1Amount);

        assertMintParam(result.params[0], poolKey.tickSpacing, positions[0], address(3));
        assertMintParam(result.params[1], poolKey.tickSpacing, positions[1], address(3));
        assertTakePairParam(result.params[4], poolKey.currency0, poolKey.currency1, address(4));
    }

    function test_fuzz_resolveAndToPlan(
        int24 currentTick,
        int24 tickSpacing,
        uint128 currency0Amount,
        uint128 currency1Amount,
        uint24 weight0
    ) public view {
        tickSpacing = int24(bound(tickSpacing, TickMath.MIN_TICK_SPACING, TickMath.MAX_TICK_SPACING));
        currentTick = int24(bound(currentTick, TickMath.MIN_TICK / 2, TickMath.MAX_TICK / 2));
        currency0Amount = uint128(bound(currency0Amount, 1, type(uint96).max));
        currency1Amount = uint128(bound(currency1Amount, 1, type(uint96).max));
        weight0 = uint24(bound(weight0, 1, 1e7 - 1));

        PoolKey memory poolKey = _poolKey(tickSpacing);

        RelativeTickBounds[] memory defs = new RelativeTickBounds[](2);
        defs[0] = RelativeTickBounds({offsetLower: TickMath.MIN_TICK, offsetUpper: TickMath.MAX_TICK});
        defs[1] = RelativeTickBounds({offsetLower: TickMath.MIN_TICK, offsetUpper: TickMath.MAX_TICK});

        TickBounds[] memory tickBounds = mockPositionPlanner.parseTicks(defs, currentTick, tickSpacing);

        uint24[] memory weights = new uint24[](2);
        weights[0] = weight0;
        weights[1] = uint24(1e7) - weight0;

        try mockPositionPlanner.resolve(tickBounds, weights, currentTick, currency0Amount, currency1Amount) returns (
            Position[] memory positions, uint128 remaining0, uint128 remaining1
        ) {
            assertLe(positions.length, 2);

            Plan memory result = mockPositionPlanner.toPlan(positions, poolKey, address(3), address(4));

            // positions + 3 settlement actions (SETTLE, SETTLE, TAKE_PAIR)
            assertEq(result.params.length, positions.length + 3);
            assertEq(result.actions.length, positions.length + 3);
            assertLe(remaining0, currency0Amount);
            assertLe(remaining1, currency1Amount);
        } catch {}
    }

    function _poolKey(int24 tickSpacing) private pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(1)),
            fee: 3000,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(0))
        });
    }
}
