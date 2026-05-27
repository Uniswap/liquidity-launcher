// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Low-level representation of a call to PositionManager
struct Plan {
    bytes actions;
    bytes[] params;
}

/// @notice A weighted liquidity position specified as tick offsets from the pool's current tick
/// @dev The sentinel pair (offsetLower = MIN_TICK, offsetUpper = MAX_TICK) resolves to full range
struct PositionDefinition {
    int24 offsetLower; // tick offset from the current tick for the position's lower bound
    int24 offsetUpper; // tick offset from the current tick for the position's upper bound
    uint24 weight; // allocation weight in mps (1e7 = 100%); all weights in a plan must sum to 1e7
    address recipient; // recipient of the minted LP position
}

/// @notice Generic struct representing a liquidity position
struct Position {
    uint128 amount0;
    uint128 amount1;
    int24 tickLower;
    int24 tickUpper;
    uint128 liquidity;
    address recipient;
}
