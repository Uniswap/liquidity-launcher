# PositionFeesForwarder
[Git Source](https://github.com/Uniswap/token-launcher/blob/49827f7454f22af093d9c28dd4f43a04f86b3b5c/src/periphery/PositionFeesForwarder.sol)

**Inherits:**
[TimelockedPositionRecipient](/src/periphery/TimelockedPositionRecipient.sol/contract.TimelockedPositionRecipient.md), [Multicall](/src/Multicall.sol/abstract.Multicall.md)

**Title:**
PositionFeesForwarder

Utility contract for holding v4 LP positions and forwarding fees to a recipient

**Note:**
security-contact: security@uniswap.org


## State Variables
### feeRecipient
The recipient of collected fees. If set to a contract, it must be able to receive ETH.


```solidity
address public immutable feeRecipient
```


## Functions
### constructor


```solidity
constructor(
    IPositionManager _positionManager,
    address _operator,
    uint256 _timelockBlockNumber,
    address _feeRecipient
) TimelockedPositionRecipient(_positionManager, _operator, _timelockBlockNumber);
```

### collectFees

Collect any fees from the position and forward them to the set recipient


```solidity
function collectFees(uint256 _tokenId) external nonReentrant;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_tokenId`|`uint256`|the token ID of the position|


## Events
### FeesForwarded
Emitted when fees are forwarded


```solidity
event FeesForwarded(address indexed feeRecipient);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`feeRecipient`|`address`|The recipient of the fees|

