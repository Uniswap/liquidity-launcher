# Address
[Git Source](https://github.com/Uniswap/token-launcher/blob/49827f7454f22af093d9c28dd4f43a04f86b3b5c/src/libraries/external/MerkleClaimHelpers.sol)

This file has been flattened to easily support multiple versions of OpenZeppelin contracts
in the same repository. MerkleClaim uses MerkleDistributorWithDeadline from merkle-distributor,
which is pinned to 0.8.17 and unfortunately does not fix its OpenZeppelin import which conflicts
with the version used in this repository. The bytecode has been confirmed to be equal to the original,
and `MerkleClaimFactory` deploys via bytecode.
Dependency links:
- openzeppelin-contracts v4.7.0: https://github.com/OpenZeppelin/openzeppelin-contracts/tree/ecd2ca2cd7cac116f7a37d0e474bbb3d7d5e1c4d
- merkle-distributor: https://github.com/Uniswap/merkle-distributor/tree/25a79e8ec8c22076a735b1a675b961c8184e7931
These depedencies have been removed from the repository and any following comments refer to the original sources

Collection of functions related to the address type


## Functions
### isContract

Returns true if `account` is a contract.
[IMPORTANT]
====
It is unsafe to assume that an address for which this function returns
false is an externally-owned account (EOA) and not a contract.
Among others, `isContract` will return false for the following
types of addresses:
- an externally-owned account
- a contract in construction
- an address where a contract will be created
- an address where a contract lived, but was destroyed
====
[IMPORTANT]
====
You shouldn't rely on `isContract` to protect against flash loan attacks!
Preventing calls from contracts is highly discouraged. It breaks composability, breaks support for smart wallets
like Gnosis Safe, and does not provide security since it can be circumvented by calling from a contract
constructor.
====


```solidity
function isContract(address account) internal view returns (bool);
```

### sendValue

Replacement for Solidity's `transfer`: sends `amount` wei to
`recipient`, forwarding all available gas and reverting on errors.
https://eips.ethereum.org/EIPS/eip-1884[EIP1884] increases the gas cost
of certain opcodes, possibly making contracts go over the 2300 gas limit
imposed by `transfer`, making them unable to receive funds via
`transfer`. [sendValue](/src/libraries/external/MerkleClaimHelpers.sol/library.Address.md#sendvalue) removes this limitation.
https://diligence.consensys.net/posts/2019/09/stop-using-soliditys-transfer-now/[Learn more].
IMPORTANT: because control is transferred to `recipient`, care must be
taken to not create reentrancy vulnerabilities. Consider using
{ReentrancyGuard} or the
https://solidity.readthedocs.io/en/v0.5.11/security-considerations.html#use-the-checks-effects-interactions-pattern[checks-effects-interactions pattern].


```solidity
function sendValue(address payable recipient, uint256 amount) internal;
```

### functionCall

Performs a Solidity function call using a low level `call`. A
plain `call` is an unsafe replacement for a function call: use this
function instead.
If `target` reverts with a revert reason, it is bubbled up by this
function (like regular Solidity function calls).
Returns the raw returned data. To convert to the expected return value,
use https://solidity.readthedocs.io/en/latest/units-and-global-variables.html?highlight=abi.decode#abi-encoding-and-decoding-functions[`abi.decode`].
Requirements:
- `target` must be a contract.
- calling `target` with `data` must not revert.
_Available since v3.1._


```solidity
function functionCall(address target, bytes memory data) internal returns (bytes memory);
```

### functionCall

Same as {xref-Address-functionCall-address-bytes-}[`functionCall`], but with
`errorMessage` as a fallback revert reason when `target` reverts.
_Available since v3.1._


```solidity
function functionCall(address target, bytes memory data, string memory errorMessage)
    internal
    returns (bytes memory);
```

### functionCallWithValue

Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
but also transferring `value` wei to `target`.
Requirements:
- the calling contract must have an ETH balance of at least `value`.
- the called Solidity function must be `payable`.
_Available since v3.1._


```solidity
function functionCallWithValue(address target, bytes memory data, uint256 value) internal returns (bytes memory);
```

### functionCallWithValue

Same as {xref-Address-functionCallWithValue-address-bytes-uint256-}[`functionCallWithValue`], but
with `errorMessage` as a fallback revert reason when `target` reverts.
_Available since v3.1._


```solidity
function functionCallWithValue(address target, bytes memory data, uint256 value, string memory errorMessage)
    internal
    returns (bytes memory);
```

### functionStaticCall

Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
but performing a static call.
_Available since v3.3._


```solidity
function functionStaticCall(address target, bytes memory data) internal view returns (bytes memory);
```

### functionStaticCall

Same as {xref-Address-functionCall-address-bytes-string-}[`functionCall`],
but performing a static call.
_Available since v3.3._


```solidity
function functionStaticCall(address target, bytes memory data, string memory errorMessage)
    internal
    view
    returns (bytes memory);
```

### functionDelegateCall

Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
but performing a delegate call.
_Available since v3.4._


```solidity
function functionDelegateCall(address target, bytes memory data) internal returns (bytes memory);
```

### functionDelegateCall

Same as {xref-Address-functionCall-address-bytes-string-}[`functionCall`],
but performing a delegate call.
_Available since v3.4._


```solidity
function functionDelegateCall(address target, bytes memory data, string memory errorMessage)
    internal
    returns (bytes memory);
```

### verifyCallResult

Tool to verifies that a low level call was successful, and revert if it wasn't, either by bubbling the
revert reason using the provided one.
_Available since v4.3._


```solidity
function verifyCallResult(bool success, bytes memory returndata, string memory errorMessage)
    internal
    pure
    returns (bytes memory);
```

