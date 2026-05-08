// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickCalculations} from "src/libraries/TickCalculations.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

contract TickCalculationsHelper is Test {
    function tickFloor(int24 tick, int24 tickSpacing) public pure returns (int24) {
        return TickCalculations.tickFloor(tick, tickSpacing);
    }
}

contract TickCalculationsTest is Test {
    TickCalculationsHelper tickCalculationsHelper;

    function setUp() public {
        tickCalculationsHelper = new TickCalculationsHelper();
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
}
