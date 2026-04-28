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
import {Plan, Position, PositionDefinition} from "src/types/PositionPlannerTypes.sol";

contract MockPositionPlanner {
    function validate(PositionDefinition[] memory definitions) external pure {
        PositionPlanner.validate(definitions);
    }

    function resolve(
        PositionDefinition[] memory definitions,
        int24 currentTick,
        int24 tickSpacing,
        uint128 currency0Amount,
        uint128 currency1Amount
    ) external pure returns (Position[] memory, uint128, uint128) {
        return PositionPlanner.resolve(definitions, currentTick, tickSpacing, currency0Amount, currency1Amount);
    }

    function toPlan(Position[] memory positions, PoolKey memory poolKey, address positionRecipient)
        external
        pure
        returns (Plan memory)
    {
        return PositionPlanner.toPlan(positions, poolKey, positionRecipient);
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

    function assertSettleParam(bytes memory param, Currency expectedCurrency) public pure {
        (Currency currency, uint256 amount, bool payerIsUser) = abi.decode(param, (Currency, uint256, bool));
        assertEq(Currency.unwrap(currency), Currency.unwrap(expectedCurrency));
        assertEq(amount, ActionConstants.CONTRACT_BALANCE);
        assertFalse(payerIsUser);
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

    // --- validate ---

    function test_validate_revertsOnEmpty() public {
        PositionDefinition[] memory defs = new PositionDefinition[](0);
        vm.expectRevert(PositionPlanner.EmptyPositionPlan.selector);
        mockPositionPlanner.validate(defs);
    }

    function test_fuzz_validate_revertsOnInvalidWeights(uint24 weight) public {
        weight = uint24(bound(weight, 1, type(uint24).max));
        vm.assume(weight != 1e7);

        PositionDefinition[] memory defs = new PositionDefinition[](1);
        defs[0] = PositionDefinition({offsetLower: TickMath.MIN_TICK, offsetUpper: TickMath.MAX_TICK, weight: weight});
        vm.expectRevert(abi.encodeWithSelector(PositionPlanner.InvalidAllocationWeights.selector, weight));
        mockPositionPlanner.validate(defs);
    }

    function test_fuzz_validate_succeedsOnValidWeights(uint24 weight0) public view {
        weight0 = uint24(bound(weight0, 1, 1e7 - 1));

        PositionDefinition[] memory defs = new PositionDefinition[](2);
        defs[0] = PositionDefinition({offsetLower: TickMath.MIN_TICK, offsetUpper: TickMath.MAX_TICK, weight: weight0});
        defs[1] = PositionDefinition({
            offsetLower: TickMath.MIN_TICK, offsetUpper: TickMath.MAX_TICK, weight: uint24(1e7) - weight0
        });

        mockPositionPlanner.validate(defs);
    }

    // --- resolve ---

    function test_resolve_skipsDegenerateBounds() public view {
        // Offsets of (0, 0) resolve to a zero-width range, which is skipped rather than reverted
        // so the migrate path never fails on malformed definitions.
        PositionDefinition[] memory defs = new PositionDefinition[](1);
        defs[0] = PositionDefinition({offsetLower: 0, offsetUpper: 0, weight: 1e7});

        (Position[] memory positions, uint128 remaining0, uint128 remaining1) =
            mockPositionPlanner.resolve(defs, 0, 10, 100e18, 100e18);

        assertEq(positions.length, 0);
        assertEq(remaining0, 100e18);
        assertEq(remaining1, 100e18);
    }

    function test_resolve_clampsOffsetsExceedingUsableRange() public view {
        // Offsets well beyond int24 boundaries should clamp to [minUsableTick, maxUsableTick]
        // rather than reverting on int24 arithmetic overflow.
        int24 tickSpacing = 60;
        PositionDefinition[] memory defs = new PositionDefinition[](1);
        defs[0] = PositionDefinition({offsetLower: type(int24).min, offsetUpper: type(int24).max, weight: 1e7});

        (Position[] memory positions,,) = mockPositionPlanner.resolve(defs, 0, tickSpacing, 100e18, 100e18);

        assertEq(positions.length, 1);
        assertEq(positions[0].tickLower, TickMath.minUsableTick(tickSpacing));
        assertEq(positions[0].tickUpper, TickMath.maxUsableTick(tickSpacing));
    }

    function test_fuzz_resolve_fullRangeSentinel(
        int24 currentTick,
        int24 tickSpacing,
        uint128 currency0Amount,
        uint128 currency1Amount
    ) public view {
        vm.assume(uint256(currency0Amount) + uint256(currency1Amount) < type(uint128).max);
        tickSpacing = int24(bound(tickSpacing, TickMath.MIN_TICK_SPACING, TickMath.MAX_TICK_SPACING));
        currentTick = int24(bound(currentTick, TickMath.MIN_TICK + 1, TickMath.MAX_TICK - 1));

        PositionDefinition[] memory defs = new PositionDefinition[](1);
        defs[0] = PositionDefinition({offsetLower: TickMath.MIN_TICK, offsetUpper: TickMath.MAX_TICK, weight: 1e7});

        (Position[] memory positions, uint128 remaining0, uint128 remaining1) =
            mockPositionPlanner.resolve(defs, currentTick, tickSpacing, currency0Amount, currency1Amount);

        assertLe(remaining0, currency0Amount);
        assertLe(remaining1, currency1Amount);
        if (positions.length == 1) {
            assertEq(positions[0].tickLower, TickMath.minUsableTick(tickSpacing));
            assertEq(positions[0].tickUpper, TickMath.maxUsableTick(tickSpacing));
        }
    }

    function test_fuzz_resolve_relativeOffsetsAlignToTickSpacing(
        int24 currentTick,
        int24 tickSpacing,
        int24 offsetLower,
        int24 offsetUpper
    ) public view {
        tickSpacing = int24(bound(tickSpacing, TickMath.MIN_TICK_SPACING, TickMath.MAX_TICK_SPACING));
        currentTick = int24(bound(currentTick, TickMath.MIN_TICK / 2, TickMath.MAX_TICK / 2));
        offsetLower = int24(bound(offsetLower, 1, 10000));
        offsetUpper = int24(bound(offsetUpper, 1, 10000));

        PositionDefinition[] memory defs = new PositionDefinition[](1);
        defs[0] = PositionDefinition({offsetLower: offsetLower, offsetUpper: offsetUpper, weight: 1e7});

        // positions.length may be 0 if the single position overflows uint128 liquidity or exhausts the budget
        (Position[] memory positions,,) = mockPositionPlanner.resolve(defs, currentTick, tickSpacing, 100e18, 100e18);
        assertLe(positions.length, 1);
        if (positions.length == 1) {
            assertLt(positions[0].tickLower, positions[0].tickUpper);
            assertEq(positions[0].tickLower % tickSpacing, 0);
            assertEq(positions[0].tickUpper % tickSpacing, 0);
            assertGe(positions[0].tickLower, TickMath.MIN_TICK);
            assertLe(positions[0].tickUpper, TickMath.MAX_TICK);
        }
    }

    function test_resolve_oneSidedAboveCurrentTick() public view {
        // offsetLower: 50, offsetUpper: 100 should intuitively mean
        // [currentTick + 50, currentTick + 100] — entirely above, token0 only
        PositionDefinition[] memory defs = new PositionDefinition[](1);
        defs[0] = PositionDefinition({offsetLower: 50, offsetUpper: 100, weight: 1e7});

        (Position[] memory positions, uint128 remaining0, uint128 remaining1) =
            mockPositionPlanner.resolve(defs, 0, 10, 100e18, 100e18);

        assertEq(positions.length, 1);
        assertGt(positions[0].amount0, 0);
        assertEq(positions[0].amount1, 0);
        assertLt(remaining0, 100e18);
        assertEq(remaining1, 100e18);
    }

    function test_resolve_oneSidedBelowCurrentTick() public view {
        // offsetLower: -100, offsetUpper: -50 should intuitively mean
        // [currentTick - 100, currentTick - 50] — entirely below, token1 only
        PositionDefinition[] memory defs = new PositionDefinition[](1);
        defs[0] = PositionDefinition({offsetLower: -100, offsetUpper: -50, weight: 1e7});

        (Position[] memory positions, uint128 remaining0, uint128 remaining1) =
            mockPositionPlanner.resolve(defs, 0, 10, 100e18, 100e18);

        assertEq(positions.length, 1);
        assertEq(positions[0].amount0, 0);
        assertGt(positions[0].amount1, 0);
        assertEq(remaining0, 100e18);
        assertLt(remaining1, 100e18);
    }

    function test_resolve_singlePositionConsumedTokensAccountedFor() public view {
        PositionDefinition[] memory defs = new PositionDefinition[](1);
        defs[0] = PositionDefinition({offsetLower: TickMath.MIN_TICK, offsetUpper: TickMath.MAX_TICK, weight: 1e7});

        // First resolve to find exact amounts the position consumes
        (Position[] memory probe,,) = mockPositionPlanner.resolve(defs, 0, 10, 100e18, 100e18);
        assertEq(probe.length, 1, "probe should create 1 position");

        // Use exact consumed amounts as budget — triggers the bug when budget hits zero
        uint128 currency0Amount = probe[0].amount0;
        uint128 currency1Amount = probe[0].amount1;

        (Position[] memory positions, uint128 remaining0, uint128 remaining1) =
            mockPositionPlanner.resolve(defs, 0, 10, currency0Amount, currency1Amount);

        assertEq(positions.length, 1, "position should be created");
        assertEq(positions[0].amount0 + remaining0, currency0Amount, "token0 not accounted for");
        assertEq(positions[0].amount1 + remaining1, currency1Amount, "token1 not accounted for");
    }

    function test_resolve_truncatesWhenBudgetExhausted() public view {
        PositionDefinition[] memory defs = new PositionDefinition[](3);
        defs[0] = PositionDefinition({offsetLower: -20, offsetUpper: 20, weight: 4e6});
        defs[1] = PositionDefinition({offsetLower: -40, offsetUpper: 40, weight: 3e6});
        defs[2] = PositionDefinition({offsetLower: -60, offsetUpper: 60, weight: 3e6});

        // Tiny budget cannot fit the full plan; saturating subtraction drops later positions
        (Position[] memory positions,,) = mockPositionPlanner.resolve(defs, 0, 10, 1000, 1000);
        assertLt(positions.length, 3);
    }

    // --- resolve → toPlan ---

    function test_toPlan_buildsFixedSharePlan() public view {
        PoolKey memory poolKey = _poolKey(10);
        int24 currentTick = 0;
        int24 tickSpacing = 10;
        uint128 currency0Amount = 100e18;
        uint128 currency1Amount = 100e18;

        PositionDefinition[] memory defs = new PositionDefinition[](2);
        defs[0] = PositionDefinition({offsetLower: TickMath.MIN_TICK, offsetUpper: TickMath.MAX_TICK, weight: 5e6});
        defs[1] = PositionDefinition({offsetLower: -20, offsetUpper: 20, weight: 5e6});

        (Position[] memory positions, uint128 remaining0, uint128 remaining1) =
            mockPositionPlanner.resolve(defs, currentTick, tickSpacing, currency0Amount, currency1Amount);

        Plan memory result = mockPositionPlanner.toPlan(positions, poolKey, address(3));

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
        assertSettleParam(result.params[2], poolKey.currency0);
        assertSettleParam(result.params[3], poolKey.currency1);
        assertTakePairParam(result.params[4], poolKey.currency0, poolKey.currency1, address(3));
    }

    function test_toPlan_emptyPositions() public view {
        PoolKey memory poolKey = _poolKey(10);
        Plan memory result = mockPositionPlanner.toPlan(new Position[](0), poolKey, address(3));

        assertEq(
            result.actions, abi.encodePacked(uint8(Actions.SETTLE), uint8(Actions.SETTLE), uint8(Actions.TAKE_PAIR))
        );
        assertEq(result.params.length, 3);
        assertSettleParam(result.params[0], poolKey.currency0);
        assertSettleParam(result.params[1], poolKey.currency1);
        assertTakePairParam(result.params[2], poolKey.currency0, poolKey.currency1, address(3));
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

        PositionDefinition[] memory defs = new PositionDefinition[](2);
        defs[0] = PositionDefinition({offsetLower: TickMath.MIN_TICK, offsetUpper: TickMath.MAX_TICK, weight: weight0});
        defs[1] = PositionDefinition({
            offsetLower: TickMath.MIN_TICK, offsetUpper: TickMath.MAX_TICK, weight: uint24(1e7) - weight0
        });

        (Position[] memory positions, uint128 remaining0, uint128 remaining1) =
            mockPositionPlanner.resolve(defs, currentTick, tickSpacing, currency0Amount, currency1Amount);

        Plan memory result = mockPositionPlanner.toPlan(positions, poolKey, address(3));

        // positions + 3 settlement actions (SETTLE, SETTLE, TAKE_PAIR)
        assertLe(positions.length, 2);
        assertEq(result.params.length, positions.length + 3);
        assertEq(result.actions.length, positions.length + 3);

        // consumed amounts are bounded by budgets (equality when no skip; inequality on saturation skip)
        uint256 consumed0;
        uint256 consumed1;
        for (uint256 i; i < positions.length; i++) {
            consumed0 += positions[i].amount0;
            consumed1 += positions[i].amount1;
        }
        assertLe(consumed0 + remaining0, currency0Amount);
        assertLe(consumed1 + remaining1, currency1Amount);
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
