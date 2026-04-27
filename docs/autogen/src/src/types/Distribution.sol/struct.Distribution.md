# Distribution
[Git Source](https://github.com/Uniswap/token-launcher/blob/49827f7454f22af093d9c28dd4f43a04f86b3b5c/src/types/Distribution.sol)

**Title:**
Distribution

Represents one distribution instruction: which strategy to use, how many tokens, and any custom data


```solidity
struct Distribution {
address strategy;
uint128 amount;
bytes configData;
}
```

