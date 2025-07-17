// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleDistributor} from "@uniswap/contracts/MerkleDistributor.sol";
import {IDistributionContract} from "../interfaces/IDistributionContract.sol";
import {IMerkleClaim} from "../interfaces/IMerkleClaim.sol";

contract MerkleClaim is MerkleDistributor, IDistributionContract, IMerkleClaim {
    using SafeERC20 for IERC20;

    /// @inheritdoc IMerkleClaim
    address public immutable owner;
    
    /// @inheritdoc IMerkleClaim
    uint256 public immutable deadline;

    constructor(
        address _token,
        bytes32 _merkleRoot,
        address _owner,
        uint256 _deadline
    ) MerkleDistributor(_token, _merkleRoot) {
        owner = _owner;
        deadline = _deadline;
    }

    /// @inheritdoc IMerkleClaim
    function claim(
        uint256 index,
        address account,
        uint256 amount,
        bytes32[] calldata merkleProof
    ) public override {
        if (deadline != 0 && block.number > deadline) {
            revert ClaimExpired();
        }
        
        super.claim(index, account, amount, merkleProof);
    }

    /// @inheritdoc IMerkleClaim
    function sweep() external {
        if (msg.sender != owner) revert OnlyOwner();
        if (deadline == 0 || block.number <= deadline) revert ClaimStillActive();
        
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) {
            IERC20(token).safeTransfer(owner, balance);
            emit TokensSwept(owner, balance);
        }
    }

}