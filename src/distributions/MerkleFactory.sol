// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

import {IERC20} from "../interfaces/external/IERC20.sol";
import {IDistributionStrategy} from "../interfaces/IDistributionStrategy.sol";
import {IDistributionContract} from "../interfaces/IDistributionContract.sol";
import {MerkleClaim} from "../distributionContracts/MerkleClaim.sol";

error ZeroAddress();

contract MerkleClaimFactory is IDistributionStrategy {
    /// @notice Deploys a new MerkleClaim and funds it with `amount` tokens.
    /// @param token The ERC-20 token to distribute.
    /// @param amount Amount of `token` intended for distribution.
    /// @param configData ABI-encoded (merkleRoot, owner, endTime) where endTime is optional (0 = no deadline).
    /// @return distributionContract The freshly deployed MerkleClaim.
    function initializeDistribution(address token, uint256 amount, bytes calldata configData)
        external
        override
        returns (IDistributionContract distributionContract)
    {
        if (token == address(0)) revert ZeroAddress();

        // Decode the merkle root, owner, and endTime from configData
        (bytes32 merkleRoot, address owner, uint256 endTime) = abi.decode(configData, (bytes32, address, uint256));

        return IDistributionContract(new MerkleClaim(token, merkleRoot, owner, endTime));
    }
}
