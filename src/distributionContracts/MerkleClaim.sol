// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

import {MerkleDistributorWithDeadline} from "merkle-distributor/contracts/MerkleDistributorWithDeadline.sol";
import {IDistributionContract} from "../interfaces/IDistributionContract.sol";

/// @title MerkleClaim
/// @notice A contract that allows users to claim tokens from a merkle distribution
contract MerkleClaim is MerkleDistributorWithDeadline, IDistributionContract {
    constructor(address _token, bytes32 _merkleRoot, address _owner, uint256 _endTime)
        MerkleDistributorWithDeadline(_token, _merkleRoot, _endTime == 0 ? type(uint256).max : _endTime)
    {
        // Transfer ownership to the specified owner
        _transferOwnership(_owner);
    }

    /// @inheritdoc IDistributionContract
    function onTokensReceived() external {}
}
