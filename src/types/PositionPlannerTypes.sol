// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Low-level representation of a call to PositionManager
struct Plan {
    bytes actions;
    bytes[] params;
}

struct RelativeTickBounds {
    int24 offsetLower;
    int24 offsetUpper;
}

/// @notice Generic struct representing a liquidity position
struct Position {
    uint128 amount0;
    uint128 amount1;
    int24 tickLower;
    int24 tickUpper;
    uint128 liquidity;
}
