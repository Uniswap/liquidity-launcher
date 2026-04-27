# IDistributionContract
[Git Source](https://github.com/Uniswap/token-launcher/blob/49827f7454f22af093d9c28dd4f43a04f86b3b5c/src/interfaces/IDistributionContract.sol)

**Title:**
IDistributionContract

Interface for token distribution contracts.


## Functions
### onTokensReceived

Notify a distribution contract that it has received the tokens to distribute


```solidity
function onTokensReceived() external;
```

## Errors
### InvalidToken
Error thrown when the token address is invalid


```solidity
error InvalidToken(address token);
```

### InvalidAmountReceived
Error thrown when the amount received is invalid upon receiving tokens


```solidity
error InvalidAmountReceived(uint256 expected, uint256 received);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`expected`|`uint256`|The expected amount|
|`received`|`uint256`|The received amount|

