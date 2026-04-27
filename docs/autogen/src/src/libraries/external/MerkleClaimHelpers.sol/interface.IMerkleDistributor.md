# IMerkleDistributor
[Git Source](https://github.com/Uniswap/token-launcher/blob/49827f7454f22af093d9c28dd4f43a04f86b3b5c/src/libraries/external/MerkleClaimHelpers.sol)


## Functions
### token


```solidity
function token() external view returns (address);
```

### merkleRoot


```solidity
function merkleRoot() external view returns (bytes32);
```

### isClaimed


```solidity
function isClaimed(uint256 index) external view returns (bool);
```

### claim


```solidity
function claim(uint256 index, address account, uint256 amount, bytes32[] calldata merkleProof) external;
```

## Events
### Claimed

```solidity
event Claimed(uint256 index, address account, uint256 amount);
```

