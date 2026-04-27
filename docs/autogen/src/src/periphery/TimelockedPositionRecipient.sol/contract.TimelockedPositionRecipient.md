# TimelockedPositionRecipient
[Git Source](https://github.com/Uniswap/token-launcher/blob/49827f7454f22af093d9c28dd4f43a04f86b3b5c/src/periphery/TimelockedPositionRecipient.sol)

**Inherits:**
[ITimelockedPositionRecipient](/src/interfaces/ITimelockedPositionRecipient.sol/interface.ITimelockedPositionRecipient.md), ReentrancyGuardTransient, BlockNumberish

**Title:**
TimelockedPositionRecipient

Utility contract for holding v4 LP positions until a timelock period has passed


## State Variables
### positionManager
The position manager that will be used to create the position


```solidity
IPositionManager public immutable positionManager
```


### operator
The operator that will be approved to transfer the position


```solidity
address public immutable operator
```


### timelockBlockNumber
The block number at which the operator will be approved to transfer the position


```solidity
uint256 public immutable timelockBlockNumber
```


## Functions
### constructor


```solidity
constructor(IPositionManager _positionManager, address _operator, uint256 _timelockBlockNumber) ;
```

### approveOperator

Approves the operator to transfer all v4 positions held by this contract

Can be called by anyone after the timelock period has passed


```solidity
function approveOperator() external;
```

### receive

Receive ETH


```solidity
receive() external payable;
```

