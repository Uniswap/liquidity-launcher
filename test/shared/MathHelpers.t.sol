// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

library MathHelpers {
    function tickSpacingToMaxLiquidityPerTick(int24 tickSpacing) public pure returns (uint128 result) {
        int24 MAX_TICK = TickMath.MAX_TICK;
        int24 MIN_TICK = TickMath.MIN_TICK;
        // tick spacing will never be 0 since TickMath.MIN_TICK_SPACING is 1
        assembly ("memory-safe") {
            tickSpacing := signextend(2, tickSpacing)
            let minTick := sub(sdiv(MIN_TICK, tickSpacing), slt(smod(MIN_TICK, tickSpacing), 0))
            let maxTick := sdiv(MAX_TICK, tickSpacing)
            let numTicks := add(sub(maxTick, minTick), 1)
            result := div(sub(shl(128, 1), 1), numTicks)
        }
    }
}
