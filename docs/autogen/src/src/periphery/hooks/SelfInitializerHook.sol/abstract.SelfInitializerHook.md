# SelfInitializerHook
[Git Source](https://github.com/Uniswap/token-launcher/blob/49827f7454f22af093d9c28dd4f43a04f86b3b5c/src/periphery/hooks/SelfInitializerHook.sol)

**Inherits:**
BaseHook

**Title:**
SelfInitializerHook

Hook contract that only allows itself to initialize the pool


## Functions
### constructor


```solidity
constructor(IPoolManager _poolManager) BaseHook(_poolManager);
```

### getHookPermissions

Returns a struct of permissions to signal which hook functions are to be implemented

Used at deployment to validate the address correctly represents the expected permissions


```solidity
function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`Hooks.Permissions`|Permissions struct|


### _beforeInitialize


```solidity
function _beforeInitialize(address sender, PoolKey calldata, uint160) internal view override returns (bytes4);
```

## Errors
### InvalidInitializer
Error thrown when the caller of `initializePool` is not address(this)


```solidity
error InvalidInitializer(address caller, address expected);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`caller`|`address`|The invalid address attempting to initialize the pool|
|`expected`|`address`|address(this)|

