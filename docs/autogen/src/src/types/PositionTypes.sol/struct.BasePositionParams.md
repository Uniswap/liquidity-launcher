# BasePositionParams
[Git Source](https://github.com/Uniswap/token-launcher/blob/49827f7454f22af093d9c28dd4f43a04f86b3b5c/src/types/PositionTypes.sol)

Base parameters shared by all position types


```solidity
struct BasePositionParams {
address currency;
address poolToken;
uint24 poolLPFee;
int24 poolTickSpacing;
uint160 initialSqrtPriceX96;
uint128 liquidity;
address positionRecipient;
IHooks hooks;
}
```

