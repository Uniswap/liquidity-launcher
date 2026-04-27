# ActionsBuilder
[Git Source](https://github.com/Uniswap/token-launcher/blob/49827f7454f22af093d9c28dd4f43a04f86b3b5c/src/libraries/ActionsBuilder.sol)

**Title:**
ActionsBuilder

Library for building position actions and parameters


## Functions
### init

Initializes an empty actions byte array


```solidity
function init() internal pure returns (bytes memory actions);
```

### addMint

Add mint action to actions byte array


```solidity
function addMint(bytes memory actions) internal pure returns (bytes memory);
```

### addSettle

Add settle action to actions byte array


```solidity
function addSettle(bytes memory actions) internal pure returns (bytes memory);
```

### addTakePair

Add take pair action to actions byte array


```solidity
function addTakePair(bytes memory actions) internal pure returns (bytes memory);
```

