// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

import {MerkleDistributorWithDeadline} from "merkle-distributor/contracts/MerkleDistributorWithDeadline.sol";
import {IERC20} from "../interfaces/external/IERC20.sol";
import {IDistributionContract} from "../interfaces/IDistributionContract.sol";

/// @title MerkleClaim
/// @notice A contract that allows users to claim tokens from a merkle distribution
/// @custom:security-contact security@uniswap.org
contract MerkleClaim is MerkleDistributorWithDeadline, IDistributionContract {
    constructor(address _token, bytes32 _merkleRoot, address _owner, uint256 _endTime)
        MerkleDistributorWithDeadline(_token, _merkleRoot, _endTime == 0 ? type(uint256).max : _endTime)
    {
        if (_token == address(0)) {
            revert InvalidToken(address(_token));
        }
        // Transfer ownership to the specified owner
        _transferOwnership(_owner);
    }

    /// @inheritdoc IDistributionContract
    function onTokensReceived() external {}
}
