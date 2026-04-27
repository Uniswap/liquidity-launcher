# MigratorParameters
[Git Source](https://github.com/Uniswap/token-launcher/blob/49827f7454f22af093d9c28dd4f43a04f86b3b5c/src/types/MigratorParameters.sol)

**Title:**
MigratorParameters

Parameters for the AdvancedLBPStrategy contract


```solidity
struct MigratorParameters {
uint64 migrationBlock; // block number when the migration can begin
address currency; // the currency that the token will be paired with in the v4 pool (currency that the initializer raised funds in)
uint24 poolLPFee; // the LP fee that the v4 pool will use
int24 poolTickSpacing; // the tick spacing that the v4 pool will use
uint24 tokenSplit; // the percentage of the total supply of the token that will be sent to the initializer, expressed in mps (1e7 = 100%)
address initializerFactory; // the initializer factory that will be used to create the initializer
address positionRecipient; // the address that will receive the position
uint64 sweepBlock; // the block number when the operator can sweep currency and tokens from the pool
address operator; // the address that is able to sweep currency and tokens from the pool
uint128 maxCurrencyAmountForLP; // the maximum amount of currency that can be used for LP
}
```

