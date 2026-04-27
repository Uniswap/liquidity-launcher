# IERC20Permit
[Git Source](https://github.com/Uniswap/token-launcher/blob/49827f7454f22af093d9c28dd4f43a04f86b3b5c/src/libraries/external/MerkleClaimHelpers.sol)

Interface of the ERC20 Permit extension allowing approvals to be made via signatures, as defined in
https://eips.ethereum.org/EIPS/eip-2612[EIP-2612].
Adds the [permit](/src/libraries/external/MerkleClaimHelpers.sol/interface.IERC20Permit.md#permit) method, which can be used to change an account's ERC20 allowance (see [IERC20-allowance](/lib/v4-core/src/interfaces/external/IERC20Minimal.sol/interface.IERC20Minimal.md#allowance)) by
presenting a message signed by the account. By not relying on [IERC20-approve](/lib/v4-core/src/interfaces/external/IERC20Minimal.sol/interface.IERC20Minimal.md#approve), the token holder account doesn't
need to send a transaction, and thus is not required to hold Ether at all.


## Functions
### permit

Sets `value` as the allowance of `spender` over ``owner``'s tokens,
given ``owner``'s signed approval.
IMPORTANT: The same issues [IERC20-approve](/lib/v4-core/src/interfaces/external/IERC20Minimal.sol/interface.IERC20Minimal.md#approve) has related to transaction
ordering also apply here.
Emits an {Approval} event.
Requirements:
- `spender` cannot be the zero address.
- `deadline` must be a timestamp in the future.
- `v`, `r` and `s` must be a valid `secp256k1` signature from `owner`
over the EIP712-formatted function arguments.
- the signature must use ``owner``'s current nonce (see [nonces](/src/libraries/external/MerkleClaimHelpers.sol/interface.IERC20Permit.md#nonces)).
For more information on the signature format, see the
https://eips.ethereum.org/EIPS/eip-2612#specification[relevant EIP
section].


```solidity
function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
    external;
```

### nonces

Returns the current nonce for `owner`. This value must be
included whenever a signature is generated for [permit](/src/libraries/external/MerkleClaimHelpers.sol/interface.IERC20Permit.md#permit).
Every successful call to [permit](/src/libraries/external/MerkleClaimHelpers.sol/interface.IERC20Permit.md#permit) increases ``owner``'s nonce by one. This
prevents a signature from being used multiple times.


```solidity
function nonces(address owner) external view returns (uint256);
```

### DOMAIN_SEPARATOR

Returns the domain separator used in the encoding of the signature for [permit](/src/libraries/external/MerkleClaimHelpers.sol/interface.IERC20Permit.md#permit), as defined by {EIP712}.


```solidity
function DOMAIN_SEPARATOR() external view returns (bytes32);
```

