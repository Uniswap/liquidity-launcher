# LiquidityLauncher
[Git Source](https://github.com/Uniswap/token-launcher/blob/49827f7454f22af093d9c28dd4f43a04f86b3b5c/src/LiquidityLauncher.sol)

**Inherits:**
[ILiquidityLauncher](/src/interfaces/ILiquidityLauncher.sol/interface.ILiquidityLauncher.md), [Multicall](/src/Multicall.sol/abstract.Multicall.md), [Permit2Forwarder](/src/Permit2Forwarder.sol/contract.Permit2Forwarder.md)

**Title:**
LiquidityLauncher

A contract that allows users to create tokens and distribute them via one or more strategies

**Note:**
security-contact: security@uniswap.org


## Functions
### constructor


```solidity
constructor(IAllowanceTransfer _permit2) Permit2Forwarder(_permit2);
```

### createToken

Creates and distributes tokens.
1) Deploys a token via chosen factory.
2) Distributes tokens via one or more strategies.


```solidity
function createToken(
    address factory,
    string calldata name,
    string calldata symbol,
    uint8 decimals,
    uint128 initialSupply,
    address recipient,
    bytes calldata tokenData
) external override returns (address tokenAddress);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`factory`|`address`|Address of the factory to use|
|`name`|`string`|Token name|
|`symbol`|`string`|Token symbol|
|`decimals`|`uint8`|Token decimals|
|`initialSupply`|`uint128`|Total tokens to be minted (to this contract)|
|`recipient`|`address`|The address that will receive the newly minted tokens. Should only be set to address(this) when distributing tokens in the same transaction via multicall. For all other cases, use a different recipient address to avoid tokens being distributed by another caller|
|`tokenData`|`bytes`|Extra data needed by the factory|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`tokenAddress`|`address`|The address of the token that was created|


### distributeToken

Transfer tokens already created to this contract and distribute them via one or more strategies


```solidity
function distributeToken(address token, Distribution calldata distribution, bool payerIsUser, bytes32 salt)
    external
    override
    returns (IDistributionContract distributionContract);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`token`|`address`||
|`distribution`|`Distribution`|Distribution instructions|
|`payerIsUser`|`bool`|Whether the payer is the user|
|`salt`|`bytes32`|The salt to pass into the distribution strategy contract if needed|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`distributionContract`|`IDistributionContract`|The address of the distribution contract|


### getGraffiti

Calculates the graffiti that will be used for a token creation


```solidity
function getGraffiti(address originalCreator) public pure returns (bytes32 graffiti);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`originalCreator`|`address`|The address that will be set as the original creator|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`graffiti`|`bytes32`|The graffiti bytes32 that will be used|


### _transferToken

Transfers tokens to the distribution contract


```solidity
function _transferToken(address token, address from, address to, uint256 amount) internal;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`token`|`address`|The address of the token to transfer|
|`from`|`address`|The address to transfer the tokens from (this contract or the user)|
|`to`|`address`|The distribution contract address to transfer the tokens to|
|`amount`|`uint256`|The amount of tokens to transfer|


### _mapPayer

Calculates the payer for an action (this contract or the user)


```solidity
function _mapPayer(bool payerIsUser) internal view returns (address);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`payerIsUser`|`bool`|Whether the payer is the user|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`address`|payer The address of the payer|


