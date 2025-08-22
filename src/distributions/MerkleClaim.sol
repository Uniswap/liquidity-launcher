// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleDistributorWithDeadline} from "@uniswap/contracts/MerkleDistributorWithDeadline.sol";
import {IDistributionContract} from "../interfaces/IDistributionContract.sol";
import {IMerkleClaim} from "../interfaces/IMerkleClaim.sol";

contract MerkleClaim is MerkleDistributorWithDeadline, IDistributionContract, IMerkleClaim {
    using SafeERC20 for IERC20;

    error InsufficientTokensReceived(uint256 expected, uint256 actual);

    constructor(address _token, bytes32 _merkleRoot, address _owner, uint256 _endTime)
        MerkleDistributorWithDeadline(_token, _merkleRoot, _endTime == 0 ? type(uint256).max : _endTime)
    {
        // Transfer ownership to the specified owner
        _transferOwnership(_owner);
    }

    /// @inheritdoc IDistributionContract
    function onTokensReceived(address _token, uint256 amount) external {
        // Verify the contract received at least the expected amount
        uint256 balance = IERC20(_token).balanceOf(address(this));
        if (balance < amount) {
            revert InsufficientTokensReceived(amount, balance);
        }
    }

    /// @inheritdoc IMerkleClaim
    function sweep() external {
        // Get the balance before withdrawal
        uint256 balance = IERC20(token).balanceOf(address(this));

        // Use the parent's withdraw function
        withdraw();

        // Emit event with the actual amount swept
        emit TokensSwept(owner(), balance);
    }
}
