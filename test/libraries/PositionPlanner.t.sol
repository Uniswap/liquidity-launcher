// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {PositionPlanner} from "src/libraries/PositionPlanner.sol";
import {Plan, Position, PositionDefinition} from "src/types/PositionPlannerTypes.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {TickCalculations} from "src/libraries/TickCalculations.sol";

contract MockPositionPlanner {
    function validate(PositionDefinition[] memory definitions) external pure {
        PositionPlanner.validate(definitions);
    }

    function resolve(
        PositionDefinition[] memory definitions,
        uint160 sqrtPriceX96,
        int24 tickSpacing,
        uint256 currency0Amount,
        uint256 currency1Amount
    ) external pure returns (Position[] memory, uint256, uint256) {
        return PositionPlanner.resolve(definitions, sqrtPriceX96, tickSpacing, currency0Amount, currency1Amount);
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

    function test_validate_succeedsOnEmpty() public view {
        PositionDefinition[] memory defs = new PositionDefinition[](0);
        mockPositionPlanner.validate(defs);
    }

    function test_fuzz_validate_revertsOnWeightsAboveMPS(uint24 weight) public {
        weight = uint24(bound(weight, 1e7 + 1, type(uint24).max));

        PositionDefinition[] memory defs = new PositionDefinition[](1);
        defs[0] = PositionDefinition({offsetLower: TickMath.MIN_TICK, offsetUpper: TickMath.MAX_TICK, weight: weight});
        vm.expectRevert(abi.encodeWithSelector(PositionPlanner.InvalidAllocationWeights.selector, weight));
        mockPositionPlanner.validate(defs);
    }

    function test_validate_revertsOnZeroPositionWeight() public {
        PositionDefinition[] memory defs = new PositionDefinition[](2);
        defs[0] = PositionDefinition({offsetLower: TickMath.MIN_TICK, offsetUpper: TickMath.MAX_TICK, weight: 0});
        defs[1] = PositionDefinition({offsetLower: -100, offsetUpper: 100, weight: 1e7});

        vm.expectRevert(abi.encodeWithSelector(PositionPlanner.ZeroPositionWeight.selector, 0));
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

    function test_fuzz_validate_succeedsWhenWeightsBelowMPS(uint24 weight) public view {
        weight = uint24(bound(weight, 1, 1e7));

        PositionDefinition[] memory defs = new PositionDefinition[](1);
        defs[0] = PositionDefinition({offsetLower: TickMath.MIN_TICK, offsetUpper: TickMath.MAX_TICK, weight: weight});

        mockPositionPlanner.validate(defs);
    }

    function test_fuzz_validate_revertsOnInvalidTickBounds(int24 offsetLower, int24 offsetUpper) public {
        offsetLower = int24(bound(offsetLower, TickMath.MIN_TICK, TickMath.MAX_TICK));
        offsetUpper = int24(bound(offsetUpper, TickMath.MIN_TICK, offsetLower));

        PositionDefinition[] memory defs = new PositionDefinition[](1);
        defs[0] = PositionDefinition({offsetLower: offsetLower, offsetUpper: offsetUpper, weight: 1e7});

        vm.expectRevert(abi.encodeWithSelector(PositionPlanner.InvalidTickBounds.selector, offsetLower, offsetUpper));
        mockPositionPlanner.validate(defs);
    }

    function test_validate_succeedsAtMaxPositionCount() public view {
        PositionDefinition[] memory defs = new PositionDefinition[](PositionPlanner.MAX_POSITIONS_PER_PLAN);
        for (uint256 i; i < defs.length; i++) {
            uint24 weight =
                i == defs.length - 1 ? uint24(1e7 - (PositionPlanner.MAX_POSITIONS_PER_PLAN - 1)) : uint24(1);
            defs[i] = PositionDefinition({offsetLower: -100, offsetUpper: 100, weight: weight});
        }

        mockPositionPlanner.validate(defs);
    }

    function test_validate_revertsWhenPositionCountExceedsMax() public {
        PositionDefinition[] memory defs = new PositionDefinition[](PositionPlanner.MAX_POSITIONS_PER_PLAN + 1);
        for (uint256 i; i < defs.length; i++) {
            uint24 weight = i == defs.length - 1 ? uint24(1e7 - PositionPlanner.MAX_POSITIONS_PER_PLAN) : uint24(1);
            defs[i] = PositionDefinition({offsetLower: -100, offsetUpper: 100, weight: weight});
        }

        vm.expectRevert(
            abi.encodeWithSelector(
                PositionPlanner.TooManyPositions.selector,
                PositionPlanner.MAX_POSITIONS_PER_PLAN + 1,
                PositionPlanner.MAX_POSITIONS_PER_PLAN
            )
        );
        mockPositionPlanner.validate(defs);
    }

    function test_resolve_clampsOffsetsExceedingUsableRange() public view {
        // Offsets well beyond int24 boundaries should clamp to [minUsableTick, maxUsableTick]
        // rather than reverting on int24 arithmetic overflow.
        int24 tickSpacing = 60;
        PositionDefinition[] memory defs = new PositionDefinition[](1);
        defs[0] = PositionDefinition({offsetLower: type(int24).min, offsetUpper: type(int24).max, weight: 1e7});

        (Position[] memory positions,,) =
            mockPositionPlanner.resolve(defs, TickMath.getSqrtPriceAtTick(0), tickSpacing, 100e18, 100e18);

        assertGe(positions.length, 1);
        assertEq(positions[0].tickLower, TickMath.minUsableTick(tickSpacing));
        assertEq(positions[0].tickUpper, TickMath.maxUsableTick(tickSpacing));
    }

    function test_resolve_emptyDefinitionsCreatesFullRangeFallback() public view {
        PositionDefinition[] memory defs = new PositionDefinition[](0);

        (Position[] memory positions, uint256 remaining0, uint256 remaining1) =
            mockPositionPlanner.resolve(defs, TickMath.getSqrtPriceAtTick(0), 10, 100e18, 100e18);

        assertEq(positions.length, 1);
        assertEq(positions[0].tickLower, TickMath.minUsableTick(10));
        assertEq(positions[0].tickUpper, TickMath.maxUsableTick(10));
        assertGt(positions[0].liquidity, 0);
        assertLt(remaining0, 100e18);
        assertLt(remaining1, 100e18);
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

        (Position[] memory positions, uint256 remaining0, uint256 remaining1) = mockPositionPlanner.resolve(
            defs, TickMath.getSqrtPriceAtTick(currentTick), tickSpacing, currency0Amount, currency1Amount
        );

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

        // positions.length may include the explicit position and an implicit full-range fallback.
        (Position[] memory positions,,) =
            mockPositionPlanner.resolve(defs, TickMath.getSqrtPriceAtTick(currentTick), tickSpacing, 100e18, 100e18);
        assertLe(positions.length, 2);
        for (uint256 i; i < positions.length; i++) {
            assertLt(positions[i].tickLower, positions[i].tickUpper);
            assertEq(positions[i].tickLower % tickSpacing, 0);
            assertEq(positions[i].tickUpper % tickSpacing, 0);
            assertGe(positions[i].tickLower, TickMath.MIN_TICK);
            assertLe(positions[i].tickUpper, TickMath.MAX_TICK);
        }
    }

    function test_resolve_oneSidedAboveCurrentTick() public view {
        // offsetLower: 50, offsetUpper: 100 should intuitively mean
        // [currentTick + 50, currentTick + 100] — entirely above, token0 only
        PositionDefinition[] memory defs = new PositionDefinition[](1);
        defs[0] = PositionDefinition({offsetLower: 50, offsetUpper: 100, weight: 1e7});

        (Position[] memory positions, uint256 remaining0, uint256 remaining1) =
            mockPositionPlanner.resolve(defs, TickMath.getSqrtPriceAtTick(0), 10, 100e18, 100e18);

        assertEq(positions.length, 1);
        assertEq(positions[0].tickLower, 50);
        assertEq(positions[0].tickUpper, 100);
        assertEq(remaining0, 0);
        assertEq(remaining1, 100e18);
    }

    function test_resolve_oneSidedBelowCurrentTick() public view {
        // offsetLower: -100, offsetUpper: -50 should intuitively mean
        // [currentTick - 100, currentTick - 50] — entirely below, token1 only
        PositionDefinition[] memory defs = new PositionDefinition[](1);
        defs[0] = PositionDefinition({offsetLower: -100, offsetUpper: -50, weight: 1e7});

        (Position[] memory positions, uint256 remaining0, uint256 remaining1) =
            mockPositionPlanner.resolve(defs, TickMath.getSqrtPriceAtTick(0), 10, 100e18, 100e18);

        assertEq(positions.length, 1);
        assertEq(positions[0].tickLower, -100);
        assertEq(positions[0].tickUpper, -50);
        assertEq(remaining0, 100e18);
        assertEq(remaining1, 0);
    }

    function test_resolve_singlePositionConsumedTokensAccountedFor() public view {
        PositionDefinition[] memory defs = new PositionDefinition[](1);
        defs[0] = PositionDefinition({offsetLower: TickMath.MIN_TICK, offsetUpper: TickMath.MAX_TICK, weight: 1e7});

        // First resolve to find exact amounts the position consumes
        (Position[] memory probe,,) =
            mockPositionPlanner.resolve(defs, TickMath.getSqrtPriceAtTick(0), 10, 100e18, 100e18);
        assertGt(probe.length, 0, "probe should create positions");

        // Use exact consumed amounts as budget — triggers the bug when budget hits zero
        uint256 currency0Amount;
        uint256 currency1Amount;
        for (uint256 i; i < probe.length; i++) {
            currency0Amount += probe[i].amount0;
            currency1Amount += probe[i].amount1;
        }

        (Position[] memory positions, uint256 remaining0, uint256 remaining1) =
            mockPositionPlanner.resolve(defs, TickMath.getSqrtPriceAtTick(0), 10, currency0Amount, currency1Amount);

        uint256 consumed0;
        uint256 consumed1;
        for (uint256 i; i < positions.length; i++) {
            consumed0 += positions[i].amount0;
            consumed1 += positions[i].amount1;
        }
        assertGt(positions.length, 0, "position should be created");
        assertEq(consumed0 + remaining0, currency0Amount, "token0 not accounted for");
        assertEq(consumed1 + remaining1, currency1Amount, "token1 not accounted for");
    }

    function test_resolve_truncatesWhenBudgetExhausted() public view {
        PositionDefinition[] memory defs = new PositionDefinition[](3);
        defs[0] = PositionDefinition({offsetLower: -20, offsetUpper: 20, weight: 4e6});
        defs[1] = PositionDefinition({offsetLower: -40, offsetUpper: 40, weight: 3e6});
        defs[2] = PositionDefinition({offsetLower: -60, offsetUpper: 60, weight: 3e6});

        (Position[] memory positions,,) =
            mockPositionPlanner.resolve(defs, TickMath.getSqrtPriceAtTick(0), 10, 1000, 1000);
        assertLe(positions.length, defs.length + 1);
    }

    function test_resolve_skipsPositionAboveMaxLiquidityPerTick() public view {
        PositionDefinition[] memory defs = new PositionDefinition[](1);
        defs[0] = PositionDefinition({offsetLower: -1, offsetUpper: 1, weight: 1e7});

        uint128 amount = uint128(type(int128).max);
        (Position[] memory positions, uint256 remaining0, uint256 remaining1) =
            mockPositionPlanner.resolve(defs, TickMath.getSqrtPriceAtTick(0), 1, amount, amount);

        assertEq(positions.length, 0);
        assertEq(remaining0, amount);
        assertEq(remaining1, amount);
    }

    function test_resolve_partialExplicitWeightsLeaveFullRangeFallback() public view {
        PositionDefinition[] memory explicitOnly = new PositionDefinition[](1);
        explicitOnly[0] = PositionDefinition({offsetLower: -20, offsetUpper: 20, weight: 4e6});

        PositionDefinition[] memory fullRangeOnly = new PositionDefinition[](0);

        (Position[] memory explicitPositions,,) =
            mockPositionPlanner.resolve(explicitOnly, TickMath.getSqrtPriceAtTick(0), 10, 100e18, 100e18);
        (Position[] memory fallbackOnly,,) =
            mockPositionPlanner.resolve(fullRangeOnly, TickMath.getSqrtPriceAtTick(0), 10, 100e18, 100e18);

        assertEq(explicitPositions.length, 2);
        assertEq(explicitPositions[0].tickLower, -20);
        assertEq(explicitPositions[0].tickUpper, 20);
        assertEq(explicitPositions[1].tickLower, TickMath.minUsableTick(10));
        assertEq(explicitPositions[1].tickUpper, TickMath.maxUsableTick(10));
        assertGt(explicitPositions[1].liquidity, 0);
        assertGt(fallbackOnly[0].liquidity, 0);
    }

    function test_resolve_skippedPositionAllocateToFullRange() public view {
        PositionDefinition[] memory defs = new PositionDefinition[](2);
        // First position definition is invalid as it resolves to MAX_TICK == MAX_TICK
        defs[0] = PositionDefinition({offsetLower: 1, offsetUpper: 2, weight: 4e6});
        defs[1] = PositionDefinition({offsetLower: TickMath.MIN_TICK, offsetUpper: TickMath.MAX_TICK, weight: 6e6});

        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(TickMath.MAX_TICK - 1);
        (Position[] memory positions,,) = mockPositionPlanner.resolve(defs, sqrtPriceX96, 10, 100e18, 100e18);

        assertEq(positions.length, 2);
        // Should create two positions: the defined full range with 60% weight and the fall back with the remainder
        assertEq(positions[0].tickLower, TickMath.minUsableTick(10));
        assertEq(positions[0].tickUpper, TickMath.maxUsableTick(10));
        assertEq(positions[1].tickLower, TickMath.minUsableTick(10));
        assertEq(positions[1].tickUpper, TickMath.maxUsableTick(10));
        // Assert ratios are correct between the two positions
        assertEq(positions[0].liquidity, positions[1].liquidity * 6e6 / 4e6);
    }

    function test_resolve_skippedPositionAllocateToFullRange_fuzz(uint24 weight0) public view {
        // Fuzz the weight of the skipped position
        weight0 = uint24(bound(weight0, 1, 1e7 - 1));
        PositionDefinition[] memory defs = new PositionDefinition[](1);
        defs[0] = PositionDefinition({offsetLower: 1, offsetUpper: 2, weight: weight0});

        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(TickMath.MAX_TICK - 1);
        (Position[] memory positions,,) = mockPositionPlanner.resolve(defs, sqrtPriceX96, 10, 100e18, 100e18);
        assertEq(positions.length, 1);
        assertEq(positions[0].tickLower, TickMath.minUsableTick(10));
        assertEq(positions[0].tickUpper, TickMath.maxUsableTick(10));
        assertEq(
            positions[0].liquidity,
            // Should be 100% weight, using the rollover from the skipped position
            LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(positions[0].tickLower),
                TickMath.getSqrtPriceAtTick(positions[0].tickUpper),
                100e18,
                100e18
            )
        );
    }

    function test_resolve_keepsDefinitionsInInputOrder() public view {
        PositionDefinition[] memory defs = new PositionDefinition[](2);
        defs[0] = PositionDefinition({offsetLower: TickMath.MIN_TICK, offsetUpper: TickMath.MAX_TICK, weight: 5e6});
        defs[1] = PositionDefinition({offsetLower: -20, offsetUpper: 20, weight: 5e6});

        (Position[] memory positions,,) =
            mockPositionPlanner.resolve(defs, TickMath.getSqrtPriceAtTick(0), 10, 100e18, 100e18);

        assertGe(positions.length, 2);
        assertEq(positions[0].tickLower, TickMath.minUsableTick(10));
        assertEq(positions[0].tickUpper, TickMath.maxUsableTick(10));
        assertEq(positions[1].tickLower, -20);
        assertEq(positions[1].tickUpper, 20);
    }

    function test_resolve_neverReturnsEmptyPositions(uint256 seed, uint8 cnt, int24 tickSpacing, uint160 sqrtPriceX96, uint128 amount0, uint128 amount1)
        public
        view
    {
        if (tickSpacing < 0) tickSpacing = TickMath.MIN_TICK_SPACING;
        tickSpacing = int24(bound(tickSpacing, TickMath.MIN_TICK_SPACING, TickMath.MAX_TICK_SPACING));
        sqrtPriceX96 = uint160(
            bound(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK / 2),
                TickMath.getSqrtPriceAtTick(TickMath.MAX_TICK / 2)
            )
        );
        cnt = uint8(bound(cnt, 1, PositionPlanner.MAX_POSITIONS_PER_PLAN));

        int24 currentTick = TickCalculations.tickFloor(TickMath.getTickAtSqrtPrice(sqrtPriceX96), tickSpacing);
        vm.assume(currentTick != TickMath.MIN_TICK && currentTick != TickMath.MAX_TICK);

        PositionDefinition[] memory defs = new PositionDefinition[](cnt);
        uint24 weight = uint24(uint256(1e7) / cnt);
        for (uint256 i; i < defs.length; i++) {
            (int24 offsetLower, int24 offsetUpper) = _fuzzTickOffsets(seed, currentTick, tickSpacing);
            defs[i] = PositionDefinition({offsetLower: offsetLower, offsetUpper: offsetUpper, weight: weight});
        }
        // Validate the position defs
        mockPositionPlanner.validate(defs);

        (Position[] memory positions,,) =
            mockPositionPlanner.resolve(defs, sqrtPriceX96, int24(tickSpacing), amount0, amount1);
        // At least one position should be created
        assertGt(positions.length, 0, "At least one position should be created");
        for (uint256 i; i < positions.length; i++) {
            assertGt(positions[i].liquidity, 0, "Any created positions should have liquidity");
        }
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

        (Position[] memory positions, uint256 remaining0, uint256 remaining1) = mockPositionPlanner.resolve(
            defs, TickMath.getSqrtPriceAtTick(currentTick), tickSpacing, currency0Amount, currency1Amount
        );

        Plan memory result = mockPositionPlanner.toPlan(positions, poolKey, address(3));

        assertEq(result.params.length, positions.length + 3);
        assertEq(result.actions.length, positions.length + 3);
        assertLe(remaining0, currency0Amount);
        assertLe(remaining1, currency1Amount);

        for (uint256 i; i < positions.length; i++) {
            assertEq(uint8(result.actions[i]), uint8(Actions.MINT_POSITION));
            assertMintParam(result.params[i], poolKey.tickSpacing, positions[i], address(3));
        }
        uint256 offset = positions.length;
        assertSettleParam(result.params[offset], poolKey.currency0);
        assertSettleParam(result.params[offset + 1], poolKey.currency1);
        assertTakePairParam(result.params[offset + 2], poolKey.currency0, poolKey.currency1, address(3));
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

    function test_fuzz_toPlan_supportsVariablePositionCount(uint8 positionCount, bytes32 seed) public view {
        PoolKey memory poolKey = _poolKey(10);
        positionCount = uint8(bound(positionCount, 0, PositionPlanner.MAX_POSITIONS_PER_PLAN));
        Position[] memory positions = new Position[](positionCount);
        for (uint256 i; i < positions.length; i++) {
            uint256 entropy = uint256(keccak256(abi.encode(seed, i)));
            int24 tickLower = int24(int256(bound(entropy, 1, 10_000)) * -1);
            int24 tickUpper = int24(int256(bound(entropy >> 16, 1, 10_000)));
            positions[i] = Position({
                amount0: uint128(bound(entropy >> 32, 0, type(uint128).max)),
                amount1: uint128(bound(entropy >> 64, 0, type(uint128).max)),
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidity: uint128(bound(entropy >> 96, 1, type(uint128).max))
            });
        }

        Plan memory result = mockPositionPlanner.toPlan(positions, poolKey, address(3));

        assertEq(result.params.length, positions.length + 3);
        assertEq(result.actions.length, positions.length + 3);
        for (uint256 i; i < positions.length; i++) {
            assertEq(uint8(result.actions[i]), uint8(Actions.MINT_POSITION));
            assertMintParam(result.params[i], poolKey.tickSpacing, positions[i], address(3));
        }
        uint256 offset = positions.length;
        assertEq(uint8(result.actions[offset]), uint8(Actions.SETTLE));
        assertEq(uint8(result.actions[offset + 1]), uint8(Actions.SETTLE));
        assertEq(uint8(result.actions[offset + 2]), uint8(Actions.TAKE_PAIR));
        assertSettleParam(result.params[offset], poolKey.currency0);
        assertSettleParam(result.params[offset + 1], poolKey.currency1);
        assertTakePairParam(result.params[offset + 2], poolKey.currency0, poolKey.currency1, address(3));
    }

    function test_fuzz_resolveAndToPlan(
        int24 currentTick,
        int24 tickSpacing,
        uint256 currency0Amount,
        uint256 currency1Amount,
        uint8 positionCount,
        bytes32 seed
    ) public view {
        tickSpacing = int24(bound(tickSpacing, TickMath.MIN_TICK_SPACING, TickMath.MAX_TICK_SPACING));
        currentTick = int24(bound(currentTick, TickMath.MIN_TICK / 2, TickMath.MAX_TICK / 2));
        currency0Amount = uint128(bound(currency0Amount, 1, type(uint96).max));
        currency1Amount = uint128(bound(currency1Amount, 1, type(uint96).max));
        positionCount = uint8(bound(positionCount, 1, PositionPlanner.MAX_POSITIONS_PER_PLAN));

        PoolKey memory poolKey = _poolKey(tickSpacing);

        PositionDefinition[] memory defs = new PositionDefinition[](positionCount);
        uint24 remainingWeight = 1e7;
        for (uint256 i; i < defs.length; i++) {
            uint24 weight;
            if (i == defs.length - 1) {
                weight = remainingWeight;
            } else {
                uint24 positionsLeft = uint24(defs.length - i - 1);
                uint256 entropy = uint256(keccak256(abi.encode(seed, i)));
                weight = uint24(bound(entropy, 1, remainingWeight - positionsLeft));
                remainingWeight -= weight;
            }
            defs[i] =
                PositionDefinition({offsetLower: TickMath.MIN_TICK, offsetUpper: TickMath.MAX_TICK, weight: weight});
        }

        (Position[] memory positions, uint256 remaining0, uint256 remaining1) = mockPositionPlanner.resolve(
            defs, TickMath.getSqrtPriceAtTick(currentTick), tickSpacing, currency0Amount, currency1Amount
        );

        Plan memory result = mockPositionPlanner.toPlan(positions, poolKey, address(3));

        // positions + 3 settlement actions (SETTLE, SETTLE, TAKE_PAIR)
        assertLe(positions.length, defs.length + 1);
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
        assertMaxLiquidityPerTick(positions, tickSpacing);
    }

    function assertMaxLiquidityPerTick(Position[] memory positions, int24 tickSpacing) public pure {
        uint128 maxLiquidityPerTick = Pool.tickSpacingToMaxLiquidityPerTick(tickSpacing);
        for (uint256 i; i < positions.length; i++) {
            uint256 lowerLiquidity;
            uint256 upperLiquidity;
            for (uint256 j; j < positions.length; j++) {
                if (
                    positions[j].tickLower == positions[i].tickLower || positions[j].tickUpper == positions[i].tickLower
                ) {
                    lowerLiquidity += positions[j].liquidity;
                }
                if (
                    positions[j].tickLower == positions[i].tickUpper || positions[j].tickUpper == positions[i].tickUpper
                ) {
                    upperLiquidity += positions[j].liquidity;
                }
            }
            assertLe(lowerLiquidity, maxLiquidityPerTick);
            assertLe(upperLiquidity, maxLiquidityPerTick);
        }
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

    /// @notice Fuzz the tick offsets for a given seed, current tick, and tick spacing
    function _fuzzTickOffsets(uint256 seed, int24 currentTick, int24 tickSpacing) private pure returns (int24, int24) {
        int24 minUsableTick = TickMath.minUsableTick(tickSpacing);
        int24 maxUsableTick = TickMath.maxUsableTick(tickSpacing);
        // minOffset is the signed offset between currentTick and minUsableTick
        int24 minOffset = minUsableTick - currentTick;
        // maxOffset is the signed offset between currentTick and maxUsableTick
        int24 maxOffset = maxUsableTick - currentTick;

        uint256 absRange = uint256(int256(maxOffset) - int256(minOffset) + 1);

        int24 offsetLower = int24(
            _bound(int256(uint256(keccak256(abi.encode(seed, 0))) % absRange), int256(minOffset), int256(maxOffset))
        );
        int24 offsetUpper = int24(
            _bound(int256(uint256(keccak256(abi.encode(seed, 1))) % absRange), int256(minOffset), int256(maxOffset))
        );
        if (offsetLower == offsetUpper) {
            if (offsetUpper < maxOffset) offsetUpper++;
            else offsetLower--;
        }
        // Ensure ordering is right
        if (offsetLower > offsetUpper) {
            (offsetLower, offsetUpper) = (offsetUpper, offsetLower);
        }
        return (offsetLower, offsetUpper);
    }
}
