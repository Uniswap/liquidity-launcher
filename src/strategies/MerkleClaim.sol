// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

import "src/libraries/external/MerkleClaimHelpers.sol";

/// @title MerkleClaim
/// @notice A contract that allows users to claim tokens from a merkle distribution
/// @dev At exactly `endTime`, both `claim()` and `withdraw()` are permitted, so the (trusted) owner can withdraw in
///      the same block a last-second claimer is claiming. Left as-is to keep byte-for-byte equality with the audited
///      upstream Uniswap merkle-distributor, which is what `MerkleClaimFactory` deploys.
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

