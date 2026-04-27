# MerkleClaim
[Git Source](https://github.com/Uniswap/token-launcher/blob/49827f7454f22af093d9c28dd4f43a04f86b3b5c/src/strategies/MerkleClaim.sol)

**Inherits:**
[MerkleDistributorWithDeadline](/src/libraries/external/MerkleClaimHelpers.sol/contract.MerkleDistributorWithDeadline.md), [IDistributionContract](/src/libraries/external/MerkleClaimHelpers.sol/interface.IDistributionContract.md)

**Title:**
MerkleClaim

A contract that allows users to claim tokens from a merkle distribution

**Note:**
security-contact: security@uniswap.org


## Functions
### constructor


```solidity
constructor(address _token, bytes32 _merkleRoot, address _owner, uint256 _endTime)
    MerkleDistributorWithDeadline(_token, _merkleRoot, _endTime == 0 ? type(uint256).max : _endTime);
```

### onTokensReceived

Notify a distribution contract that it has received the tokens to distribute


```solidity
function onTokensReceived() external;
```

