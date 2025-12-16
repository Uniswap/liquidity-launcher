// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {MerkleClaim} from "../strategies/MerkleClaim.sol";
import {IDistributionContract} from "../interfaces/IDistributionContract.sol";
import {IDistributionStrategy} from "../interfaces/IDistributionStrategy.sol";

/// @title MerkleClaimFactory
/// @notice Factory for the MerkleClaim contract
/// @custom:security-contact security@uniswap.org
contract MerkleClaimFactory is IDistributionStrategy {
    /// @notice Deploys a new MerkleClaim
    /// @param token The ERC-20 token to distribute
    /// @param totalSupply Amount of `token` intended for distribution.
    /// @param configData ABI-encoded (merkleRoot, owner, endTime) where endTime is optional (0 = no deadline).
    /// @param salt The salt for deterministic deployment
    /// @return distributionContract The freshly deployed MerkleClaim.
    function initializeDistribution(address token, uint256 totalSupply, bytes calldata configData, bytes32 salt)
        external
        override
        returns (IDistributionContract distributionContract)
    {
        // Decode the merkle root, owner, and endTime from configData
        (bytes32 merkleRoot, address owner, uint256 endTime) = abi.decode(configData, (bytes32, address, uint256));

        // Hash the salt with msg.sender to prevent front-running
        bytes32 _salt = keccak256(abi.encode(msg.sender, salt));
        distributionContract = IDistributionContract(new MerkleClaim{salt: _salt}(token, merkleRoot, owner, endTime));

        emit DistributionInitialized(address(distributionContract), token, totalSupply);
    }

    /// @notice Get the address that a MerkleClaim contract would be deployed to
    /// @param token The address of the ERC-20 token to distribute
    /// @param configData ABI-encoded (merkleRoot, owner, endTime) where endTime is optional (0 = no deadline)
    /// @param salt The salt for deterministic deployment
    /// @param sender The address that will be used for salt hashing
    /// @return merkleClaimAddress The address where the MerkleClaim would be deployed
    function getMerkleClaimAddress(address token, bytes calldata configData, bytes32 salt, address sender)
        external
        view
        returns (address merkleClaimAddress)
    {
        // Decode the merkle root, owner, and endTime from configData
        (bytes32 merkleRoot, address owner, uint256 endTime) = abi.decode(configData, (bytes32, address, uint256));

        // Hash the salt with sender to match initializeDistribution logic
        bytes32 _salt = keccak256(abi.encode(sender, salt));

        bytes32 initCodeHash =
            keccak256(abi.encodePacked(type(MerkleClaim).creationCode, abi.encode(token, merkleRoot, owner, endTime)));
        return Create2.computeAddress(_salt, initCodeHash, address(this));
    }
}
