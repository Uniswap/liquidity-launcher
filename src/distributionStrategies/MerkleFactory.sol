// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

import {IDistributionStrategy} from "../interfaces/IDistributionStrategy.sol";
import {IDistributionContract} from "../interfaces/IDistributionContract.sol";
import {MerkleClaim} from "../distributionContracts/MerkleClaim.sol";

contract MerkleClaimFactory is IDistributionStrategy {
    /// @notice Deploys a new MerkleClaim
    /// @param token The ERC-20 token to distribute
    /// @param totalSupply Amount of `token` intended for distribution.
    /// @param configData ABI-encoded (merkleRoot, owner, endTime) where endTime is optional (0 = no deadline).
    /// @param salt The salt for deterministic deployment
    /// @return distributionContract The freshly deployed MerkleClaim.
    function initializeDistribution(address token, uint128 totalSupply, bytes calldata configData, bytes32 salt)
        external
        override
        returns (IDistributionContract distributionContract)
    {
        // Decode the merkle root, owner, and endTime from configData
        (bytes32 merkleRoot, address owner, uint256 endTime) = abi.decode(configData, (bytes32, address, uint256));

        distributionContract = IDistributionContract(new MerkleClaim{salt: salt}(token, merkleRoot, owner, endTime));

        emit DistributionInitialized(address(distributionContract), token, totalSupply);
    }
}
