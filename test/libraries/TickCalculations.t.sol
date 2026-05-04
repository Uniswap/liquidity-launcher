// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TickMath} from '@uniswap/v4-core/src/libraries/TickMath.sol';
import {Test} from 'forge-std/Test.sol';
import {TickCalculations} from 'src/libraries/TickCalculations.sol';

contract TickCalculationsHelper is Test {
    function tickSpacingToMaxLiquidityPerTick(int24 tickSpacing) public pure returns (uint128) {
        return TickCalculations.tickSpacingToMaxLiquidityPerTick(tickSpacing);
    }

    function tickFloor(int24 tick, int24 tickSpacing) public pure returns (int24) {
        return TickCalculations.tickFloor(tick, tickSpacing);
    }

    function tickStrictCeil(int24 tick, int24 tickSpacing) public pure returns (int24) {
        return TickCalculations.tickStrictCeil(tick, tickSpacing);
    }
}

contract TickCalculationsTest is Test {
    TickCalculationsHelper tickCalculationsHelper;

    function setUp() public {
        tickCalculationsHelper = new TickCalculationsHelper();
    }

    function test_tickSpacingToMaxLiquidityPerTick() public view {
        uint128 liquidity = tickCalculationsHelper.tickSpacingToMaxLiquidityPerTick(10);
        assertEq(liquidity, 1_917_559_095_893_846_719_543_856_547_154_045);

        liquidity = tickCalculationsHelper.tickSpacingToMaxLiquidityPerTick(60);
        assertEq(liquidity, 11_505_354_575_363_080_317_263_139_282_924_270);

        liquidity = tickCalculationsHelper.tickSpacingToMaxLiquidityPerTick(200);
        assertEq(liquidity, 38_345_995_821_606_768_476_828_330_790_147_420);

        liquidity = tickCalculationsHelper.tickSpacingToMaxLiquidityPerTick(TickMath.MIN_TICK_SPACING);
        assertEq(liquidity, 191_757_530_477_355_301_479_181_766_273_477);

        liquidity = tickCalculationsHelper.tickSpacingToMaxLiquidityPerTick(TickMath.MAX_TICK_SPACING);
        assertEq(liquidity, 6_076_470_837_873_901_133_274_546_561_281_575_204);

        liquidity = tickCalculationsHelper.tickSpacingToMaxLiquidityPerTick(2302);
        assertEq(liquidity, 440_780_268_032_303_709_149_448_973_357_212_709);
    }

    function test_tickFloor() public view {
        int24 tick = tickCalculationsHelper.tickFloor(1, 1);
        assertEq(tick, 1);

        tick = tickCalculationsHelper.tickFloor(-1, 1);
        assertEq(tick, -1);

        tick = tickCalculationsHelper.tickFloor(0, 1);
        assertEq(tick, 0);

        tick = tickCalculationsHelper.tickFloor(-1, 2);
        assertEq(tick, -2);

        tick = tickCalculationsHelper.tickFloor(1, 2);
        assertEq(tick, 0);

        tick = tickCalculationsHelper.tickFloor(-1, 3);
        assertEq(tick, -3);

        tick = tickCalculationsHelper.tickFloor(1, 3);
        assertEq(tick, 0);

        tick = tickCalculationsHelper.tickFloor(-1, 4);
    }

    function test_fuzz_tickFloor(int24 tick, int24 tickSpacing) public view {
        tick = int24(bound(int24(tick), int24(TickMath.MIN_TICK), int24(TickMath.MAX_TICK)));
        tickSpacing =
            int24(bound(int24(tickSpacing), int24(TickMath.MIN_TICK_SPACING), int24(TickMath.MAX_TICK_SPACING)));

        int24 result = tickCalculationsHelper.tickFloor(tick, tickSpacing);
        assertEq(result % tickSpacing, 0);
        assertLe(result, tick);
    }

    function test_tickStrictCeil() public view {
        int24 tick = tickCalculationsHelper.tickStrictCeil(1, 1);
        assertEq(tick, 2);

        tick = tickCalculationsHelper.tickStrictCeil(-1, 1);
        assertEq(tick, 0);

        tick = tickCalculationsHelper.tickStrictCeil(0, 1);
        assertEq(tick, 1);

        tick = tickCalculationsHelper.tickStrictCeil(-1, 2);
        assertEq(tick, 0);

        tick = tickCalculationsHelper.tickStrictCeil(1, 2);
        assertEq(tick, 2);

        tick = tickCalculationsHelper.tickStrictCeil(-1, 3);
        assertEq(tick, 0);

        tick = tickCalculationsHelper.tickStrictCeil(1, 3);
        assertEq(tick, 3);

        tick = tickCalculationsHelper.tickStrictCeil(-1, 4);
        assertEq(tick, 0);

        tick = tickCalculationsHelper.tickStrictCeil(1, 4);
        assertEq(tick, 4);
    }

    function test_fuzz_tickStrictCeil(int24 tick, int24 tickSpacing) public view {
        tick = int24(bound(int24(tick), int24(TickMath.MIN_TICK), int24(TickMath.MAX_TICK)));
        tickSpacing =
            int24(bound(int24(tickSpacing), int24(TickMath.MIN_TICK_SPACING), int24(TickMath.MAX_TICK_SPACING)));

        int24 result = tickCalculationsHelper.tickStrictCeil(tick, tickSpacing);

        assertEq(result % tickSpacing, 0);
        assertGt(result, tick);
    }
}
