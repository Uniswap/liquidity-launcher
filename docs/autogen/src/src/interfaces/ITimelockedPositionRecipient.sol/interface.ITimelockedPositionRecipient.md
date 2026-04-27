# ITimelockedPositionRecipient
[Git Source](https://github.com/Uniswap/token-launcher/blob/49827f7454f22af093d9c28dd4f43a04f86b3b5c/src/interfaces/ITimelockedPositionRecipient.sol)


## Functions
### approveOperator

Approves the operator to transfer all v4 positions held by this contract

Can be called by anyone after the timelock period has passed


```solidity
function approveOperator() external;
```

### timelockBlockNumber

The block number at which the operator will be approved to transfer the position


```solidity
function timelockBlockNumber() external view returns (uint256);
```

### operator

The operator that will be approved to transfer the position


```solidity
function operator() external view returns (address);
```

### positionManager

The canonical v4 position manager


```solidity
function positionManager() external view returns (IPositionManager);
```

## Events
### OperatorApproved
Emitted when the operator is approved to transfer the position


```solidity
event OperatorApproved(address indexed operator);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`operator`|`address`|The configured operator|

## Errors
### Timelocked
Thrown when trying to approve the operator before the timelock period has passed


```solidity
error Timelocked();
```

