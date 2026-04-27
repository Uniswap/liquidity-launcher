# LBPInitializationParams
[Git Source](https://github.com/Uniswap/token-launcher/blob/49827f7454f22af093d9c28dd4f43a04f86b3b5c/src/interfaces/ILBPInitializer.sol)

General parameters for initializing an LBP strategy


```solidity
struct LBPInitializationParams {
uint256 initialPriceX96; // the price discovered by the contract
uint256 tokensSold; // the number of tokens sold by the contract
uint256 currencyRaised; // the amount of currency raised by the contract
}
```

