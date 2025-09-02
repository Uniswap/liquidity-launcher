// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

import {IERC20} from "../interfaces/external/IERC20.sol";
import {MerkleDistributorWithDeadline} from "merkle-distributor/contracts/MerkleDistributorWithDeadline.sol";
import {IDistributionContract} from "../interfaces/IDistributionContract.sol";
import {IMerkleClaim} from "../interfaces/IMerkleClaim.sol";

/// @title MerkleClaim
/// @notice A contract that allows users to claim tokens from a merkle distribution
contract MerkleClaim is MerkleDistributorWithDeadline, IMerkleClaim {
    constructor(address _token, bytes32 _merkleRoot, address _owner, uint256 _endTime)
        MerkleDistributorWithDeadline(_token, _merkleRoot, _endTime == 0 ? type(uint256).max : _endTime)
    {
        // Transfer ownership to the specified owner
        _transferOwnership(_owner);
    }

    /// @inheritdoc IDistributionContract
    function onTokensReceived() external {}

    /// @inheritdoc IMerkleClaim
    function sweep() external {
        // Get the balance before withdrawal
        uint256 balance = IERC20(token).balanceOf(address(this));

        // Use the parent's withdraw function via external call
        this.withdraw();

        // Emit event with the actual amount swept
        emit TokensSwept(owner(), balance);
    }
}
