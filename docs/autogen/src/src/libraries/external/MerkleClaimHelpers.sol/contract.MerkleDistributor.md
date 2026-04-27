# MerkleDistributor
[Git Source](https://github.com/Uniswap/token-launcher/blob/49827f7454f22af093d9c28dd4f43a04f86b3b5c/src/libraries/external/MerkleClaimHelpers.sol)

**Inherits:**
[IMerkleDistributor](/src/libraries/external/MerkleClaimHelpers.sol/interface.IMerkleDistributor.md)


## State Variables
### token

```solidity
address public immutable override token
```


### merkleRoot

```solidity
bytes32 public immutable override merkleRoot
```


### claimedBitMap

```solidity
mapping(uint256 => uint256) private claimedBitMap
```


## Functions
### constructor


```solidity
constructor(address token_, bytes32 merkleRoot_) ;
```

### isClaimed


```solidity
function isClaimed(uint256 index) public view override returns (bool);
```

### _setClaimed


```solidity
function _setClaimed(uint256 index) private;
```

### claim


```solidity
function claim(uint256 index, address account, uint256 amount, bytes32[] calldata merkleProof)
    public
    virtual
    override;
```

