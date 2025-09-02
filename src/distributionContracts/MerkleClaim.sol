// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

import {IERC20} from "../interfaces/external/IERC20.sol";
import {MerkleDistributorWithDeadline} from "merkle-distributor/contracts/MerkleDistributorWithDeadline.sol";
import {IDistributionContract} from "../interfaces/IDistributionContract.sol";
import {IMerkleClaim} from "../interfaces/IMerkleClaim.sol";

contract MerkleClaim is MerkleDistributorWithDeadline, IDistributionContract {
    error InsufficientTokensReceived(uint256 expected, uint256 actual);

    /// @notice Emitted when tokens are swept by the owner after endTime
    /// @param owner The address that swept the tokens
    /// @param amount The amount of tokens swept
    event TokensSwept(address indexed owner, uint256 amount);

    constructor(address _token, bytes32 _merkleRoot, address _owner, uint256 _endTime)
        MerkleDistributorWithDeadline(_token, _merkleRoot, _endTime == 0 ? type(uint256).max : _endTime)
    {
        // Transfer ownership to the specified owner
        _transferOwnership(_owner);
    }

    /// @inheritdoc IDistributionContract
    function onTokensReceived() external {}

    /// @notice Sweep remaining tokens to the owner after endTime
    /// @dev Only callable by owner and only after endTime has passed
    function sweep() external {
        // Get the balance before withdrawal
        uint256 balance = IERC20(token).balanceOf(address(this));

        // Use the parent's withdraw function via external call
        this.withdraw();

        // Emit event with the actual amount swept
        emit TokensSwept(owner(), balance);
    }
}
