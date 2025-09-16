// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

struct MigrationData {
    uint128 currencyAmount;
    uint256 priceX192;
    uint160 sqrtPriceX96;
    uint128 tokenAmount;
    uint128 leftoverCurrency;
    uint128 initialCurrencyAmount;
    uint128 liquidity;
    bool shouldCreateOneSided;
    bool hasOneSidedParams;
}
