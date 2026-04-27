# Permit2Forwarder
[Git Source](https://github.com/Uniswap/token-launcher/blob/49827f7454f22af093d9c28dd4f43a04f86b3b5c/src/Permit2Forwarder.sol)

**Inherits:**
[IPermit2Forwarder](/src/interfaces/IPermit2Forwarder.sol/interface.IPermit2Forwarder.md)

Permit2Forwarder allows permitting this contract as a spender on permit2

This contract does not enforce the spender to be this contract, but that is the intended use case


## State Variables
### permit2
the Permit2 contract to forward approvals


```solidity
IAllowanceTransfer public immutable permit2
```


## Functions
### constructor


```solidity
constructor(IAllowanceTransfer _permit2) ;
```

### permit

Allows forwarding a single permit to permit2


```solidity
function permit(address owner, IAllowanceTransfer.PermitSingle calldata permitSingle, bytes calldata signature)
    external
    returns (bytes memory err);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`owner`|`address`|the owner of the tokens|
|`permitSingle`|`IAllowanceTransfer.PermitSingle`|the permit data|
|`signature`|`bytes`|the signature of the permit; abi.encodePacked(r, s, v)|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`err`|`bytes`|the error returned by a reverting permit call, empty if successful|


