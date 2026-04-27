# MerkleProof
[Git Source](https://github.com/Uniswap/token-launcher/blob/49827f7454f22af093d9c28dd4f43a04f86b3b5c/src/libraries/external/MerkleClaimHelpers.sol)

These functions deal with verification of Merkle Tree proofs.
The proofs can be generated using the JavaScript library
https://github.com/miguelmota/merkletreejs[merkletreejs].
Note: the hashing algorithm should be keccak256 and pair sorting should be enabled.
See `test/utils/cryptography/MerkleProof.test.js` for some examples.
WARNING: You should avoid using leaf values that are 64 bytes long prior to
hashing, or use a hash function other than keccak256 for hashing leaves.
This is because the concatenation of a sorted pair of internal nodes in
the merkle tree could be reinterpreted as a leaf value.


## Functions
### verify

Returns true if a `leaf` can be proved to be a part of a Merkle tree
defined by `root`. For this, a `proof` must be provided, containing
sibling hashes on the branch from the leaf to the root of the tree. Each
pair of leaves and each pair of pre-images are assumed to be sorted.


```solidity
function verify(bytes32[] memory proof, bytes32 root, bytes32 leaf) internal pure returns (bool);
```

### verifyCalldata

Calldata version of [verify](/src/libraries/external/MerkleClaimHelpers.sol/library.MerkleProof.md#verify)
_Available since v4.7._


```solidity
function verifyCalldata(bytes32[] calldata proof, bytes32 root, bytes32 leaf) internal pure returns (bool);
```

### processProof

Returns the rebuilt hash obtained by traversing a Merkle tree up
from `leaf` using `proof`. A `proof` is valid if and only if the rebuilt
hash matches the root of the tree. When processing the proof, the pairs
of leafs & pre-images are assumed to be sorted.
_Available since v4.4._


```solidity
function processProof(bytes32[] memory proof, bytes32 leaf) internal pure returns (bytes32);
```

### processProofCalldata

Calldata version of [processProof](/src/libraries/external/MerkleClaimHelpers.sol/library.MerkleProof.md#processproof)
_Available since v4.7._


```solidity
function processProofCalldata(bytes32[] calldata proof, bytes32 leaf) internal pure returns (bytes32);
```

### multiProofVerify

Returns true if the `leaves` can be proved to be a part of a Merkle tree defined by
`root`, according to `proof` and `proofFlags` as described in [processMultiProof](/src/libraries/external/MerkleClaimHelpers.sol/library.MerkleProof.md#processmultiproof).
_Available since v4.7._


```solidity
function multiProofVerify(bytes32[] memory proof, bool[] memory proofFlags, bytes32 root, bytes32[] memory leaves)
    internal
    pure
    returns (bool);
```

### multiProofVerifyCalldata

Calldata version of [multiProofVerify](/src/libraries/external/MerkleClaimHelpers.sol/library.MerkleProof.md#multiproofverify)
_Available since v4.7._


```solidity
function multiProofVerifyCalldata(
    bytes32[] calldata proof,
    bool[] calldata proofFlags,
    bytes32 root,
    bytes32[] memory leaves
) internal pure returns (bool);
```

### processMultiProof

Returns the root of a tree reconstructed from `leaves` and the sibling nodes in `proof`,
consuming from one or the other at each step according to the instructions given by
`proofFlags`.
_Available since v4.7._


```solidity
function processMultiProof(bytes32[] memory proof, bool[] memory proofFlags, bytes32[] memory leaves)
    internal
    pure
    returns (bytes32 merkleRoot);
```

### processMultiProofCalldata

Calldata version of [processMultiProof](/src/libraries/external/MerkleClaimHelpers.sol/library.MerkleProof.md#processmultiproof)
_Available since v4.7._


```solidity
function processMultiProofCalldata(bytes32[] calldata proof, bool[] calldata proofFlags, bytes32[] memory leaves)
    internal
    pure
    returns (bytes32 merkleRoot);
```

### _hashPair


```solidity
function _hashPair(bytes32 a, bytes32 b) private pure returns (bytes32);
```

### _efficientHash


```solidity
function _efficientHash(bytes32 a, bytes32 b) private pure returns (bytes32 value);
```

