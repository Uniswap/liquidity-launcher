// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Create2} from "@openzeppelin-latest/contracts/utils/Create2.sol";
import {IDistributionStrategy} from "../interfaces/IDistributionStrategy.sol";
import {IDistributionContract} from "../interfaces/IDistributionContract.sol";
import {LBPStrategyBasic} from "../distributionContracts/LBPStrategyBasic.sol";
import {MigratorParameters} from "../types/MigratorParameters.sol";

/// @title LBPStrategyBasicFactory
/// @notice Factory for the LBPStrategyBasic contract
/// @custom:security-contact security@uniswap.org
contract LBPStrategyBasicFactory is IDistributionStrategy {
    /// @notice The position manager that will be used to create the position
    IPositionManager public immutable positionManager;
    /// @notice The pool manager that will be used to create the pool
    IPoolManager public immutable poolManager;

    constructor(IPositionManager _positionManager, IPoolManager _poolManager) {
        positionManager = _positionManager;
        poolManager = _poolManager;
    }

    /// @inheritdoc IDistributionStrategy
    function initializeDistribution(address token, uint256 totalSupply, bytes calldata configData, bytes32 salt)
        external
        returns (IDistributionContract lbp)
    {
        if (totalSupply > type(uint128).max) revert InvalidAmount(totalSupply, type(uint128).max);

        (MigratorParameters memory migratorParams, bytes memory auctionParams) =
            abi.decode(configData, (MigratorParameters, bytes));

        bytes32 _salt = keccak256(abi.encode(msg.sender, salt));
        lbp = IDistributionContract(
            address(
                new LBPStrategyBasic{salt: _salt}(
                    token, uint128(totalSupply), migratorParams, auctionParams, positionManager, poolManager
                )
            )
        );

        emit DistributionInitialized(address(lbp), token, totalSupply);
    }

    /// @notice Gets the address of the LBPStrategyBasic contract
    /// @param token The token that is being distributed
    /// @param totalSupply The supply of the token that will be distributed
    /// @param configData The config data for the LBPStrategyBasic contract
    /// @param salt The salt to deterministicly deploy the LBPStrategyBasic contract
    /// @param sender The address to be concatenated with the salt parameter before being hashed
    /// @return The address of the LBPStrategyBasic contract
    function getLBPAddress(address token, uint256 totalSupply, bytes calldata configData, bytes32 salt, address sender)
        external
        view
        returns (address)
    {
        if (totalSupply > type(uint128).max) revert InvalidAmount(totalSupply, type(uint128).max);

        (MigratorParameters memory migratorParams, bytes memory auctionParams) =
            abi.decode(configData, (MigratorParameters, bytes));

        bytes32 _salt = keccak256(abi.encode(sender, salt));

        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(LBPStrategyBasic).creationCode,
                abi.encode(token, uint128(totalSupply), migratorParams, auctionParams, positionManager, poolManager)
            )
        );
        return Create2.computeAddress(_salt, initCodeHash, address(this));
    }
}
