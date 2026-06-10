// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

import "src/libraries/external/MerkleClaimHelpers.sol";

/// @title MerkleClaim
/// @notice A contract that allows users to claim tokens from a merkle distribution
/// @dev Accepted risk (audit SB #12, Low): `claim()` is allowed while `block.timestamp <= endTime` and `withdraw()`
///      while `block.timestamp >= endTime`, so at exactly `endTime` both are permitted in the same block. The owner
///      could front-run a last-second claimer by withdrawing the full balance at `endTime`. This is left unchanged to
///      preserve byte-for-byte equality with the audited upstream Uniswap merkle-distributor (the deployed contract is
///      the hardcoded creation code in `MerkleClaimFactory`); the owner is already a fully trusted party.
/// @custom:security-contact security@uniswap.org
contract MerkleClaim is MerkleDistributorWithDeadline, IDistributor {
    constructor(address _token, bytes32 _merkleRoot, address _owner, uint256 _endTime)
        MerkleDistributorWithDeadline(_token, _merkleRoot, _endTime == 0 ? type(uint256).max : _endTime)
    {
        if (_token == address(0)) {
            revert InvalidToken(_token);
        }
        // Transfer ownership to the specified owner
        _transferOwnership(_owner);
    }

    /// @inheritdoc IDistributor
    function onTokensReceived() external {}
}

