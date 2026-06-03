// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IDistributor} from "./IDistributor.sol";

/// @title IDistributorFactory
/// @notice Minimal interface for factories that deploy distributors.
interface IDistributorFactory {
    /// @notice Creates a distributor without funding it.
    /// @param token The token that will be distributed.
    /// @param totalSupply The supply of the token that will be distributed.
    /// @param configData Arbitrary, factory-specific parameters.
    /// @param salt The salt for deterministic deployment, if used by the factory.
    /// @return distributor The contract that will handle or manage the distribution.
    function create(address token, uint256 totalSupply, bytes calldata configData, bytes32 salt)
        external
        returns (IDistributor distributor);

    /// @notice Returns the distributor address for the provided creation parameters.
    /// @param token The token that will be distributed.
    /// @param totalSupply The supply of the token that will be distributed.
    /// @param configData Arbitrary, factory-specific parameters.
    /// @param salt The salt for deterministic deployment, if used by the factory.
    /// @param sender The address that would call {create}.
    /// @return distributor The contract that will handle or manage the distribution.
    function getAddress(address token, uint256 totalSupply, bytes calldata configData, bytes32 salt, address sender)
        external
        view
        returns (IDistributor distributor);
}
