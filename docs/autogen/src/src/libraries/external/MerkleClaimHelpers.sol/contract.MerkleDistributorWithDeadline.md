# MerkleDistributorWithDeadline
[Git Source](https://github.com/Uniswap/token-launcher/blob/49827f7454f22af093d9c28dd4f43a04f86b3b5c/src/libraries/external/MerkleClaimHelpers.sol)

**Inherits:**
[MerkleDistributor](/src/libraries/external/MerkleClaimHelpers.sol/contract.MerkleDistributor.md), [Ownable](/src/libraries/external/MerkleClaimHelpers.sol/abstract.Ownable.md)


## State Variables
### endTime

```solidity
uint256 public immutable endTime
```


## Functions
### constructor


```solidity
constructor(address token_, bytes32 merkleRoot_, uint256 endTime_) MerkleDistributor(token_, merkleRoot_);
```

### claim


```solidity
function claim(uint256 index, address account, uint256 amount, bytes32[] calldata merkleProof) public override;
```

### withdraw


```solidity
function withdraw() external onlyOwner;
```

