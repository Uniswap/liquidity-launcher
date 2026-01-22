// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title MigrationData
/// @notice Data for the migration of the pool
struct MigrationData {
    uint160 sqrtPriceX96; // the initial sqrt price of the pool
    uint128 fullRangeTokenAmount; // the initial token amount for the full range position
    uint128 fullRangeCurrencyAmount; // the initial currency amount for the full range position
    uint128 leftoverCurrency; // the leftover currency (if any) after creating the full range position
    uint128 liquidity; // the liquidity for the full range position
}
