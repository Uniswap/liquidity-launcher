# GovernedLBPStrategy
[Git Source](https://github.com/Uniswap/token-launcher/blob/49827f7454f22af093d9c28dd4f43a04f86b3b5c/src/strategies/lbp/GovernedLBPStrategy.sol)

**Inherits:**
[FullRangeLBPStrategy](/src/strategies/lbp/FullRangeLBPStrategy.sol/contract.FullRangeLBPStrategy.md)

**Title:**
GovernedLBPStrategy

Strategy for distributing virtual tokens to a v4 pool
Virtual tokens are ERC20 tokens that wrap an underlying token.


## State Variables
### GOVERNANCE
The address of Governance who must approve migration

This can be a bridge messenger, multi-sig, EOA, or contract


```solidity
address public immutable GOVERNANCE
```


### isMigrationApproved
Whether migration is approved by Governance


```solidity
bool public isMigrationApproved = false
```


## Functions
### constructor


```solidity
constructor(
    address _token,
    uint128 _totalSupply,
    MigratorParameters memory _migratorParams,
    bytes memory _initializerParams,
    IPositionManager _positionManager,
    IPoolManager _poolManager,
    address _governance
)
    // Underlying strategy
    FullRangeLBPStrategy(_token, _totalSupply, _migratorParams, _initializerParams, _positionManager, _poolManager);
```

### approveMigration

Approves migration of the virtual token to the v4 pool

Only callable by the set address


```solidity
function approveMigration() external;
```

### getHookPermissions

Returns the permissions for the hook

Has permissions for before initialize and before swap


```solidity
function getHookPermissions() public pure override returns (Hooks.Permissions memory);
```

### _beforeSwap

Validates that migration is approved before swapping on the pool and returns a zero delta

Reverts if migration is not approved


```solidity
function _beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
    internal
    view
    override
    returns (bytes4, BeforeSwapDelta, uint24);
```

## Events
### MigrationApproved
Emitted when migration is approved by the governance address


```solidity
event MigrationApproved();
```

### GovernanceSet
Emitted when the governance address is set


```solidity
event GovernanceSet(address governance);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`governance`|`address`|The address of the governance address|

## Errors
### MigrationNotApproved
Error thrown when migration is not approved yet by the governance address


```solidity
error MigrationNotApproved();
```

### NotGovernance
Error thrown when the caller is not the governance address


```solidity
error NotGovernance();
```

