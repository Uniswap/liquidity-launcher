# Ownable
[Git Source](https://github.com/Uniswap/token-launcher/blob/49827f7454f22af093d9c28dd4f43a04f86b3b5c/src/libraries/external/MerkleClaimHelpers.sol)

**Inherits:**
[Context](/src/libraries/external/MerkleClaimHelpers.sol/abstract.Context.md)

Contract module which provides a basic access control mechanism, where
there is an account (an owner) that can be granted exclusive access to
specific functions.
By default, the owner account will be the one that deploys the contract. This
can later be changed with [transferOwnership](/src/libraries/external/MerkleClaimHelpers.sol/abstract.Ownable.md#transferownership).
This module is used through inheritance. It will make available the modifier
`onlyOwner`, which can be applied to your functions to restrict their use to
the owner.


## State Variables
### _owner

```solidity
address private _owner
```


## Functions
### constructor

Initializes the contract setting the deployer as the initial owner.


```solidity
constructor() ;
```

### onlyOwner

Throws if called by any account other than the owner.


```solidity
modifier onlyOwner() ;
```

### owner

Returns the address of the current owner.


```solidity
function owner() public view virtual returns (address);
```

### _checkOwner

Throws if the sender is not the owner.


```solidity
function _checkOwner() internal view virtual;
```

### renounceOwnership

Leaves the contract without owner. It will not be possible to call
`onlyOwner` functions anymore. Can only be called by the current owner.
NOTE: Renouncing ownership will leave the contract without an owner,
thereby removing any functionality that is only available to the owner.


```solidity
function renounceOwnership() public virtual onlyOwner;
```

### transferOwnership

Transfers ownership of the contract to a new account (`newOwner`).
Can only be called by the current owner.


```solidity
function transferOwnership(address newOwner) public virtual onlyOwner;
```

### _transferOwnership

Transfers ownership of the contract to a new account (`newOwner`).
Internal function without access restriction.


```solidity
function _transferOwnership(address newOwner) internal virtual;
```

## Events
### OwnershipTransferred

```solidity
event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
```

