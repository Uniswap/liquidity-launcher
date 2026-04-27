# ILiquidityLauncher
[Git Source](https://github.com/Uniswap/token-launcher/blob/49827f7454f22af093d9c28dd4f43a04f86b3b5c/src/interfaces/ILiquidityLauncher.sol)

**Title:**
ILiquidityLauncher

Interface for the LiquidityLauncher contract


## Functions
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
) external returns (address tokenAddress);
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
function distributeToken(address tokenAddress, Distribution memory distribution, bool payerIsUser, bytes32 salt)
    external
    returns (IDistributionContract distributionContract);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`tokenAddress`|`address`|The address of the token to distribute|
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
function getGraffiti(address originalCreator) external view returns (bytes32 graffiti);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`originalCreator`|`address`|The address that will be set as the original creator|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`graffiti`|`bytes32`|The graffiti bytes32 that will be used|


## Events
### TokenCreated
Emitted when a token is created


```solidity
event TokenCreated(address indexed tokenAddress);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`tokenAddress`|`address`|The address of the token that was created|

### TokenDistributed
Emitted when a token is distributed


```solidity
event TokenDistributed(address indexed tokenAddress, address indexed distributionContract, uint256 amount);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`tokenAddress`|`address`|The address of the token that was distributed|
|`distributionContract`|`address`|The address of the distribution contract|
|`amount`|`uint256`|The amount of tokens that were distributed|

## Errors
### RecipientCannotBeZeroAddress
Thrown when the recipient is the zero address


```solidity
error RecipientCannotBeZeroAddress();
```

