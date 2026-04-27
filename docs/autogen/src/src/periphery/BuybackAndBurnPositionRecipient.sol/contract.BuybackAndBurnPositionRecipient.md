# BuybackAndBurnPositionRecipient
[Git Source](https://github.com/Uniswap/token-launcher/blob/49827f7454f22af093d9c28dd4f43a04f86b3b5c/src/periphery/BuybackAndBurnPositionRecipient.sol)

**Inherits:**
[TimelockedPositionRecipient](/src/periphery/TimelockedPositionRecipient.sol/contract.TimelockedPositionRecipient.md)

**Title:**
BuybackAndBurnPositionRecipient

Utility contract for holding a v4 LP position and burning the fees accrued from the position

Fees can be collected once the value of the currency portion exceeds the configured minimum burn amount


## State Variables
### minTokenBurnAmount
The minimum amount of `token` which must be burned each time fees are collected


```solidity
uint256 public immutable minTokenBurnAmount
```


### token
The token that will be burned


```solidity
address public immutable token
```


### currency
The currency that will be used to collect fees


```solidity
address public immutable currency
```


### BURN_ADDRESS
The address to send tokens to be burned


```solidity
address constant BURN_ADDRESS = address(0xdead)
```


## Functions
### constructor


```solidity
constructor(
    address _token,
    address _currency,
    address _operator,
    IPositionManager _positionManager,
    uint256 _timelockBlockNumber,
    uint256 _minTokenBurnAmount
) TimelockedPositionRecipient(_positionManager, _operator, _timelockBlockNumber);
```

### collectFees

Claim any fees from the position and burn the `tokens` portion


```solidity
function collectFees(uint256 _tokenId, uint256 _minCurrencyAmount) external nonReentrant;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_tokenId`|`uint256`|The token ID of the position|
|`_minCurrencyAmount`|`uint256`||


## Events
### TokensBurned
Emitted when tokens are burned


```solidity
event TokensBurned(uint256 amount);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`amount`|`uint256`|The amount of tokens burned|

### FeesCollected
Emitted when fees are collected


```solidity
event FeesCollected(address indexed caller);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`caller`|`address`|The caller of the collectFees function|

## Errors
### InvalidToken
Thrown when the token is address(0)


```solidity
error InvalidToken();
```

### TokenAndCurrencyCannotBeTheSame
Thrown when the token and currency are the same address


```solidity
error TokenAndCurrencyCannotBeTheSame();
```

### InsufficientCurrencyReceived
Thrown when the received currency fees amount is less than expected


```solidity
error InsufficientCurrencyReceived(uint256 received, uint256 expected);
```

