# ProtocolFeeOperator
[Git Source](https://github.com/Uniswap/token-launcher/blob/49827f7454f22af093d9c28dd4f43a04f86b3b5c/src/periphery/ProtocolFeeOperator.sol)

**Inherits:**
Initializable

**Title:**
ProtocolFeeOperator

EIP1167 contract meant to be set as the `operator` of an LBP strategy
to stream a portion of the raised currency to a set protocol fee recipient over time

Ensure that `initialize` is called during deployment to prevent misuse


## State Variables
### MAX_PROTOCOL_FEE_BPS
The maximum protocol fee in basis points. Any returned fee above will be clamped to 10%


```solidity
uint24 public constant MAX_PROTOCOL_FEE_BPS = 1000
```


### BPS
Basis points denominator


```solidity
uint24 public constant BPS = 10_000
```


### protocolFeeRecipient
The recipient to send protocol fees to. Set on construction as it varies per chain


```solidity
address public immutable protocolFeeRecipient
```


### protocolFeeController
The controller that will provide the protocol fee in basis points


```solidity
IProtocolFeeController public immutable protocolFeeController
```


### recipient
The address to forward the tokens and currency to. Set on initialization

It is crucial that this is set correctly after deployment to the intended address


```solidity
address public recipient
```


### lbp
The LBP strategy to sweep the tokens and currency from. Set on initialization


```solidity
ILBPStrategyBase public lbp
```


## Functions
### constructor

Construct the implementation with immutable protocol fee recipient and controller


```solidity
constructor(address _protocolFeeRecipient, address _protocolFeeController) ;
```

### initialize

Initializes the contract. MUST be called atomically during deployment to prevent frontrunning.


```solidity
function initialize(address _lbp, address _recipient) external initializer;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_lbp`|`address`|The LBP strategy to sweep the tokens and currency from|
|`_recipient`|`address`|The address to forward the tokens and currency to|


### sweepToken

Sweeps the token from the LBP strategy, forwarding all tokens to the set recipient


```solidity
function sweepToken() external;
```

### sweepCurrency

Sweeps the currency from the LBP strategy

Forwards the protocol fee portion to the protocol fee recipient and the remaining to the set recipient


```solidity
function sweepCurrency() external;
```

### getProtocolFeeBps

Gets the protocol fee in basis points for the given currency

Returns the fee as a uint24, capped at MAX_PROTOCOL_FEE_BPS. Returns 0 if the call reverts for any reason.


```solidity
function getProtocolFeeBps(address currency, uint128 amount) public view returns (uint24 protocolFee);
```

### receive

Allows the contract to receive ETH


```solidity
receive() external payable;
```

## Events
### ProtocolFeeSwept
Emitted when protocol fees are swept


```solidity
event ProtocolFeeSwept(address indexed currency, uint256 amount);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`currency`|`address`|The currency that was swept|
|`amount`|`uint256`|The amount of currency that was swept|

### RecipientSet
Emitted when the contract is initialized


```solidity
event RecipientSet(address indexed recipient);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`recipient`|`address`|The address that was set as the recipient|

## Errors
### ProtocolFeeRecipientIsZero
General error for invalid addresses


```solidity
error ProtocolFeeRecipientIsZero();
```

### ProtocolFeeControllerAddressIsZero

```solidity
error ProtocolFeeControllerAddressIsZero();
```

### LBPAddressIsZero

```solidity
error LBPAddressIsZero();
```

### RecipientAddressIsZero

```solidity
error RecipientAddressIsZero();
```

