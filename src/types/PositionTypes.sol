// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

/// @notice Base parameters shared by all position types
struct BasePositionParams {
    address currency;
    address token;
    uint24 poolLPFee;
    int24 poolTickSpacing;
    uint160 initialSqrtPriceX96;
    uint128 liquidity;
    address positionRecipient;
    IHooks hooks;
}

/// @notice Parameters specific to full-range positions
struct FullRangeParams {
    uint128 tokenAmount;
    uint128 currencyAmount;
}

/// @notice Parameters specific to one-sided positions
struct OneSidedParams {
    uint128 amount;
    bool inToken;
}

/// @notice Tick boundaries for a position
struct TickBounds {
    int24 lowerTick;
    int24 upperTick;
}
