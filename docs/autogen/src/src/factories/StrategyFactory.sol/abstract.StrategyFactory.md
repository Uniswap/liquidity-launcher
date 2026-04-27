# StrategyFactory
[Git Source](https://github.com/Uniswap/token-launcher/blob/49827f7454f22af093d9c28dd4f43a04f86b3b5c/src/factories/StrategyFactory.sol)

**Inherits:**
[IStrategyFactory](/src/interfaces/IStrategyFactory.sol/interface.IStrategyFactory.md)

**Title:**
StrategyFactory

Abstract base factory for strategies with overridable deployment logic

**Note:**
security-contact: security@uniswap.org


## Functions
### initializeDistribution

Initialize a distribution of tokens under this strategy.

Contracts can choose to deploy an instance with a factory-model or handle all distributions within the
implementing contract. For some strategies this function will handle the entire distribution, for others it
could merely set up initial state and provide additional entrypoints to handle the distribution logic.


```solidity
function initializeDistribution(address token, uint256 totalSupply, bytes calldata configData, bytes32 salt)
    external
    virtual
    returns (IDistributionContract distributionContract);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`token`|`address`|The token that is being distributed.|
|`totalSupply`|`uint256`|The supply of the token that is being distributed.|
|`configData`|`bytes`|Arbitrary, strategy-specific parameters.|
|`salt`|`bytes32`|The optional salt for deterministic deployment.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`distributionContract`|`IDistributionContract`|The contract that will handle or manage the distribution. (Could be `address(this)` if the strategy is handled in-place, or a newly deployed instance).|


### getAddress

Precomputes the address of the deployed strategy contract via Create2

The returned address is not guaranteed to be a correct deployable address due to
construction time validity checks and hook address validation.


```solidity
function getAddress(address token, uint256 totalSupply, bytes calldata configData, bytes32 salt, address sender)
    external
    view
    virtual
    returns (address);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`token`|`address`|The address of the token to be distributed|
|`totalSupply`|`uint256`||
|`configData`|`bytes`|The configuration data for the strategy|
|`salt`|`bytes32`|The salt to use for the deterministic deployment|
|`sender`|`address`|The sender of the initializeDistribution transaction|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`address`|The address of the deployed strategy contract|


### _validateParamsAndReturnDeployedBytecode

Overridable function to validate the deployment params and return the deployed bytecode for the strategy

This function MUST revert if the given params are invalid


```solidity
function _validateParamsAndReturnDeployedBytecode(address token, uint256 totalSupply, bytes calldata configData)
    internal
    view
    virtual
    returns (bytes memory);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`token`|`address`|The address of the token to be distributed|
|`totalSupply`|`uint256`|The total supply of the token to be distributed|
|`configData`|`bytes`|The configData used to initialize the strategy|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`bytes`|The deployed bytecode for the strategy|


### _hashSenderAndSalt

Derives the salt for deployment given the sender and a provided salt


```solidity
function _hashSenderAndSalt(address _sender, bytes32 _salt) internal pure virtual returns (bytes32);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_sender`|`address`|The msg.sender of the initializeDistribution transaction|
|`_salt`|`bytes32`|The caller provided salt|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`bytes32`|The hash of the sender's address and the salt|


