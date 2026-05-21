// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IDistributionContract} from "./IDistributionContract.sol";

/// @title IDistributionContractFactory
/// @notice Minimal interface for factories that deploy distribution contracts.
interface IDistributionContractFactory {
    /// @notice Creates a distribution contract without funding it.
    /// @param token The token that will be distributed.
    /// @param totalSupply The supply of the token that will be distributed.
    /// @param configData Arbitrary, factory-specific parameters.
    /// @param salt The salt for deterministic deployment, if used by the factory.
    /// @return distributionContract The contract that will handle or manage the distribution.
    function create(address token, uint256 totalSupply, bytes calldata configData, bytes32 salt)
        external
        returns (IDistributionContract distributionContract);

    /// @notice Returns the distribution contract address for the provided creation parameters.
    /// @param token The token that will be distributed.
    /// @param totalSupply The supply of the token that will be distributed.
    /// @param configData Arbitrary, factory-specific parameters.
    /// @param salt The salt for deterministic deployment, if used by the factory.
    /// @return distributionContract The contract that will handle or manage the distribution.
    function getAddress(address token, uint256 totalSupply, bytes calldata configData, bytes32 salt)
        external
        view
        returns (IDistributionContract distributionContract);
}
