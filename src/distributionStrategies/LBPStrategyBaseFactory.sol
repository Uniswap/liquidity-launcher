// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Create2} from "@openzeppelin-latest/contracts/utils/Create2.sol";
import {IDistributionContract} from "../interfaces/IDistributionContract.sol";
import {IDistributionStrategy} from "../interfaces/IDistributionStrategy.sol";
import {IStrategyFactory} from "../interfaces/IStrategyFactory.sol";
import {LBPStrategyBase} from "../distributionContracts/LBPStrategyBase.sol";
import {MigratorParameters} from "../types/MigratorParameters.sol";

/// @title LBPStrategyBaseFactory
/// @notice Base factory for LBPStrategy contracts with overridable deployment logic
/// @custom:security-contact security@uniswap.org
abstract contract LBPStrategyBaseFactory is IStrategyFactory {
    /// @notice The position manager that will be used to create the position
    IPositionManager public immutable positionManager;
    /// @notice The pool manager that will be used to create the pool
    IPoolManager public immutable poolManager;

    constructor(IPositionManager _positionManager, IPoolManager _poolManager) {
        positionManager = _positionManager;
        poolManager = _poolManager;
    }

    /// @notice Overridable function to validate the deployment params and return the deployed bytecode for the strategy
    /// @dev This function MUST revert if the given params are invalid
    function _validateParamsAndReturnDeployedBytecode(address token, uint256 totalSupply, bytes calldata configData)
        internal
        view
        virtual
        returns (bytes memory);

    /// @notice Derives the salt for deployment given the sender and a provided salt
    /// @param _salt The caller provided salt
    function _hashSenderAndSalt(address _sender, bytes32 _salt) internal pure returns (bytes32) {
        return keccak256(abi.encode(_sender, _salt));
    }

    /// @inheritdoc IDistributionStrategy
    function initializeDistribution(address token, uint256 totalSupply, bytes calldata configData, bytes32 salt)
        external
        virtual
        returns (IDistributionContract)
    {
        bytes32 _salt = _hashSenderAndSalt(msg.sender, salt);
        bytes memory deployedBytecode = _validateParamsAndReturnDeployedBytecode(token, totalSupply, configData);
        return IDistributionContract(Create2.deploy(0, _salt, deployedBytecode));
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
}
