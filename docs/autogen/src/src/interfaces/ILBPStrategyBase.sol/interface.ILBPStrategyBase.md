# ILBPStrategyBase
[Git Source](https://github.com/Uniswap/token-launcher/blob/49827f7454f22af093d9c28dd4f43a04f86b3b5c/src/interfaces/ILBPStrategyBase.sol)

**Inherits:**
[IDistributionContract](/src/libraries/external/MerkleClaimHelpers.sol/interface.IDistributionContract.md)

**Title:**
ILBPStrategyBase

Base interface for derived LBPStrategy contracts


## Functions
### migrate

Migrates the raised funds and tokens to a v4 pool


```solidity
function migrate() external;
```

### sweepToken

Allows the operator to sweep tokens from the contract

Can only be called after sweepBlock by the operator


```solidity
function sweepToken() external;
```

### sweepCurrency

Allows the operator to sweep currency from the contract

Can only be called after sweepBlock by the operator


```solidity
function sweepCurrency() external;
```

### token

Getters


```solidity
function token() external view returns (address);
```

### currency


```solidity
function currency() external view returns (address);
```

### totalSupply


```solidity
function totalSupply() external view returns (uint128);
```

### reserveTokenAmount


```solidity
function reserveTokenAmount() external view returns (uint128);
```

### positionManager


```solidity
function positionManager() external view returns (IPositionManager);
```

### positionRecipient


```solidity
function positionRecipient() external view returns (address);
```

### migrationBlock


```solidity
function migrationBlock() external view returns (uint64);
```

### sweepBlock


```solidity
function sweepBlock() external view returns (uint64);
```

### operator


```solidity
function operator() external view returns (address);
```

### initializer


```solidity
function initializer() external view returns (ILBPInitializer);
```

### initializerParameters


```solidity
function initializerParameters() external view returns (bytes memory);
```

### poolLPFee


```solidity
function poolLPFee() external view returns (uint24);
```

### poolTickSpacing


```solidity
function poolTickSpacing() external view returns (int24);
```

### maxCurrencyAmountForLP


```solidity
function maxCurrencyAmountForLP() external view returns (uint128);
```

## Events
### Migrated
Emitted when a v4 pool is created and the liquidity is migrated to it


```solidity
event Migrated(PoolKey indexed key, uint160 initialSqrtPriceX96);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`key`|`PoolKey`|The key of the pool that was created|
|`initialSqrtPriceX96`|`uint160`|The initial sqrt price of the pool|

### InitializerCreated
Emitted when the initializer is created


```solidity
event InitializerCreated(address indexed initializer);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`initializer`|`address`|The address of the initializer contract|

### TokensSwept
Emitted when the tokens are swept


```solidity
event TokensSwept(address indexed operator, uint256 amount);
```

### CurrencySwept
Emitted when the currency is swept


```solidity
event CurrencySwept(address indexed operator, uint256 amount);
```

## Errors
### MigrationNotAllowed
Error thrown when migration to a v4 pool is not allowed yet


```solidity
error MigrationNotAllowed(uint256 migrationBlock, uint256 currentBlock);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`migrationBlock`|`uint256`|The block number at which migration is allowed|
|`currentBlock`|`uint256`|The current block number|

### InitializerMustImplementInterface
Error thrown when the initializer does not implement the ILBPInitializer interface


```solidity
error InitializerMustImplementInterface(address initializer);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`initializer`|`address`|The deployed initializer address|

### InvalidSweepBlock
Error thrown when the sweep block is before or at the migration block


```solidity
error InvalidSweepBlock(uint256 sweepBlock, uint256 migrationBlock);
```

### InvalidEndBlock
Error thrown when the end block is at orafter the migration block


```solidity
error InvalidEndBlock(uint256 endBlock, uint256 migrationBlock);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`endBlock`|`uint256`|The invalid end block|
|`migrationBlock`|`uint256`|The migration block|

### InvalidCurrency
Error thrown when the initializer currency is not the same as the strategy currency


```solidity
error InvalidCurrency(address actual, address expected);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`actual`|`address`|The initializer currency|
|`expected`|`address`|The actual currency|

### InvalidFloorPrice
Error thrown when the floor price is invalid


```solidity
error InvalidFloorPrice(uint256 floorPrice);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`floorPrice`|`uint256`|The invalid floor price|

### MaxCurrencyAmountForLPIsZero
Error thrown when the max currency amount for LP is zero


```solidity
error MaxCurrencyAmountForLPIsZero();
```

### TokenSplitTooHigh
Error thrown when the token split is too high


```solidity
error TokenSplitTooHigh(uint24 tokenSplit, uint24 maxTokenSplit);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`tokenSplit`|`uint24`|The invalid token split percentage|
|`maxTokenSplit`|`uint24`||

### InvalidTickSpacing
Error thrown when the tick spacing is greater than the max tick spacing or less than the min tick spacing


```solidity
error InvalidTickSpacing(int24 tickSpacing, int24 minTickSpacing, int24 maxTickSpacing);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`tickSpacing`|`int24`|The invalid tick spacing|
|`minTickSpacing`|`int24`||
|`maxTickSpacing`|`int24`||

### InvalidFee
Error thrown when the fee is greater than the max fee


```solidity
error InvalidFee(uint24 fee, uint24 maxFee);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`fee`|`uint24`|The invalid fee|
|`maxFee`|`uint24`||

### InvalidPositionRecipient
Error thrown when the position recipient is the zero address, address(1), or address(2)


```solidity
error InvalidPositionRecipient(address positionRecipient);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`positionRecipient`|`address`|The invalid position recipient|

### InvalidFundsRecipient
Error thrown when the funds recipient is not set to the strategy


```solidity
error InvalidFundsRecipient(address invalidFundsRecipient, address expectedFundsRecipient);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`invalidFundsRecipient`|`address`|The invalid funds recipient|
|`expectedFundsRecipient`|`address`|The expected funds recipient|

### ReserveSupplyIsTooHigh
Error thrown when the reserve supply is too high


```solidity
error ReserveSupplyIsTooHigh(uint256 reserveTokenAmount, uint256 maxReserveSupply);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`reserveTokenAmount`|`uint256`|The invalid reserve supply|
|`maxReserveSupply`|`uint256`|The maximum reserve supply (type(uint128).max)|

### InvalidLiquidity
Error thrown when the liquidity is invalid


```solidity
error InvalidLiquidity(uint128 liquidity, uint128 maxLiquidity);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`liquidity`|`uint128`|The invalid liquidity|
|`maxLiquidity`|`uint128`|The max liquidity|

### NotOperator
Error thrown when the caller is not the operator


```solidity
error NotOperator(address caller, address operator);
```

### SweepNotAllowed
Error thrown when the sweep is not allowed yet


```solidity
error SweepNotAllowed(uint256 sweepBlock, uint256 currentBlock);
```

### InvalidTokenAmount
Error thrown when the token amount is invalid


```solidity
error InvalidTokenAmount(uint128 tokenAmount, uint128 reserveTokenAmount);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`tokenAmount`|`uint128`|The invalid token amount|
|`reserveTokenAmount`|`uint128`|The reserve supply|

### InitializerTokenSplitIsZero
Error thrown when the token split to the initializer is zero. This is possible due to rounding.


```solidity
error InitializerTokenSplitIsZero();
```

### CurrencyAmountTooHigh
Error thrown when the currency amount is greater than type(uint128).max


```solidity
error CurrencyAmountTooHigh(uint256 currencyAmount, uint256 maxCurrencyAmount);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`currencyAmount`|`uint256`|The invalid currency amount|
|`maxCurrencyAmount`|`uint256`|The maximum currency amount (type(uint128).max)|

### InsufficientCurrency
Error thrown when the currency amount is invalid


```solidity
error InsufficientCurrency(uint256 amountNeeded, uint256 amountAvailable);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`amountNeeded`|`uint256`|The currency amount needed|
|`amountAvailable`|`uint256`|The balance of the currency in the contract|

### InitializerAlreadyCreated
Error thrown when the auction has already been created


```solidity
error InitializerAlreadyCreated();
```

### NoCurrencyRaised
Error thrown when no currency was raised


```solidity
error NoCurrencyRaised();
```

### AmountOverflow
Error thrown when the token amount is too high


```solidity
error AmountOverflow(uint256 tokenAmount);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`tokenAmount`|`uint256`|The invalid token amount|

