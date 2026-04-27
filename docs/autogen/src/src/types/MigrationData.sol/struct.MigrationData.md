# MigrationData
[Git Source](https://github.com/Uniswap/token-launcher/blob/49827f7454f22af093d9c28dd4f43a04f86b3b5c/src/types/MigrationData.sol)

**Title:**
MigrationData

Data for the migration of the pool


```solidity
struct MigrationData {
uint160 sqrtPriceX96; // the initial sqrt price of the pool
uint128 fullRangeTokenAmount; // the initial token amount for the full range position
uint128 fullRangeCurrencyAmount; // the initial currency amount for the full range position
uint128 leftoverCurrency; // the leftover currency (if any) after creating the full range position
uint128 liquidity; // the liquidity for the full range position
}
```

