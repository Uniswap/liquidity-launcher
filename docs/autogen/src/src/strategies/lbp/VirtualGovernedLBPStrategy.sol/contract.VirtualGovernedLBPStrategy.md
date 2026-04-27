# VirtualGovernedLBPStrategy
[Git Source](https://github.com/Uniswap/token-launcher/blob/49827f7454f22af093d9c28dd4f43a04f86b3b5c/src/strategies/lbp/VirtualGovernedLBPStrategy.sol)

**Inherits:**
[GovernedLBPStrategy](/src/strategies/lbp/GovernedLBPStrategy.sol/contract.GovernedLBPStrategy.md)

**Title:**
VirtualGovernedLBPStrategy

Strategy for distributing virtual tokens to a v4 pool requiring governance approval

Virtual tokens are ERC20 tokens that wrap an underlying token.

A version of this strategy was used in the inagural CCA token sale with the Aztec Network
deployed on mainnet: https://etherscan.io/address/0xd53006d1e3110fd319a79aeec4c527a0d265e080


## State Variables
### UNDERLYING_TOKEN
The address of the underlying token that is being distributed - used in the migrated pool


```solidity
address public immutable UNDERLYING_TOKEN
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
    GovernedLBPStrategy(
        _token, _totalSupply, _migratorParams, _initializerParams, _positionManager, _poolManager, _governance
    );
```

### _getPoolToken

Returns the address of the underlying token


```solidity
function _getPoolToken() internal view override returns (address);
```

## Errors
### UnderlyingTokenIsZeroAddress
Error thrown when the underlying token is the zero address


```solidity
error UnderlyingTokenIsZeroAddress();
```

