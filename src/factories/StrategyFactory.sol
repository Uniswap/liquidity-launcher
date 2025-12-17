// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Create2} from "@openzeppelin-latest/contracts/utils/Create2.sol";
import {IDistributionContract} from "../interfaces/IDistributionContract.sol";
import {IDistributionStrategy} from "../interfaces/IDistributionStrategy.sol";
import {IStrategyFactory} from "../interfaces/IStrategyFactory.sol";

/// @title StrategyFactory
/// @notice Abstract base factory for strategies with overridable deployment logic
/// @custom:security-contact security@uniswap.org
abstract contract StrategyFactory is IStrategyFactory {
    /// @inheritdoc IDistributionStrategy
    function initializeDistribution(address token, uint256 totalSupply, bytes calldata configData, bytes32 salt)
        external
        virtual
        returns (IDistributionContract distributionContract)
    {
        bytes32 _salt = _hashSenderAndSalt(msg.sender, salt);
        bytes memory deployedBytecode = _validateParamsAndReturnDeployedBytecode(token, totalSupply, configData);
        distributionContract = IDistributionContract(Create2.deploy(0, _salt, deployedBytecode));
        emit DistributionInitialized(address(distributionContract), token, totalSupply);
    }

    /// @inheritdoc IStrategyFactory
    function getAddress(address token, uint256 totalSupply, bytes calldata configData, bytes32 salt, address sender)
        external
        view
        virtual
        returns (address)
    {
        bytes32 _salt = _hashSenderAndSalt(sender, salt);
        bytes32 initCodeHash = keccak256(_validateParamsAndReturnDeployedBytecode(token, totalSupply, configData));
        return Create2.computeAddress(_salt, initCodeHash, address(this));
    }

    /// @notice Overridable function to validate the deployment params and return the deployed bytecode for the strategy
    /// @dev This function MUST revert if the given params are invalid
    /// @param token The address of the token to be distributed
    /// @param totalSupply The total supply of the token to be distributed
    /// @param configData The configData used to initialize the strategy
    /// @return The deployed bytecode for the strategy
    function _validateParamsAndReturnDeployedBytecode(address token, uint256 totalSupply, bytes calldata configData)
        internal
        view
        virtual
        returns (bytes memory);

    /// @notice Derives the salt for deployment given the sender and a provided salt
    /// @param _sender The msg.sender of the initializeDistribution transaction
    /// @param _salt The caller provided salt
    /// @return The hash of the sender's address and the salt
    function _hashSenderAndSalt(address _sender, bytes32 _salt) internal pure virtual returns (bytes32) {
        return keccak256(abi.encode(_sender, _salt));
    }
}
