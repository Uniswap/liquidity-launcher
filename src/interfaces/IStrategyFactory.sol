// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IDistributionStrategy} from "./IDistributionStrategy.sol";

/// @title IStrategyFactory
/// @notice Interface for strategy factories
interface IStrategyFactory is IDistributionStrategy {
    /// @notice Precomputes the address of the deployed strategy contract via Create2
    /// @dev The returned address is not guaranteed to be a correct deployable address due to
    ///      construction time validity checks and hook address validation. 
    /// @dev The `sender` should be the same as the one used to initialize the distribution
    /// @param token The address of the token to be distributed
    /// @param amount The amount of tokens intended for distribution
    /// @param configData The configuration data for the strategy
    /// @param salt The salt to use for the deterministic deployment
    /// @param sender The sender of the initializeDistribution transaction
    /// @return The address of the deployed strategy contract
    function getAddress(address token, uint256 amount, bytes calldata configData, bytes32 salt, address sender)
        external
        view
        returns (address);
}
