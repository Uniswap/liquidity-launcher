// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Low-level representation of a PositionManager call plan
struct Plan {
    bytes actions;
    bytes[] params;
}

/// @notice User-provided parameters for a desired position
struct TickOffsets {
    int24 offsetLower;
    int24 offsetUpper;
}

struct Position {
    uint128 amount0;
    uint128 amount1;
    int24 tickLower;
    int24 tickUpper;
    uint128 liquidity;
}
