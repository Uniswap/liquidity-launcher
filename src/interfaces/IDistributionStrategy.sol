// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/// @title IDistributionStrategy
/// @notice Interface for token distribution strategies.
interface IDistributionStrategy {
    /// @notice Emitted when a distribution is initialized
    event DistributionInitialized(address distributionContract, address token, uint128 totalSupply);

    /// @notice Get the addresses and amounts of the distribution
    /// @param token The token to distribute
    /// @param totalSupply The total supply of the token
    /// @param configData Arbitrary, strategy-specific parameters.
    /// @param salt The salt to use for the distribution
    /// @return addresses The addresses of the contracts that will handle or manage the distribution
    /// @return amounts The amounts of tokens that will be distributed to each address
    function getAddressesAndAmounts(address token, uint128 totalSupply, bytes calldata configData, bytes32 salt)
        external
        view
        returns (address[2] memory, uint128[2] memory);

    /// @notice Initialize a distribution of tokens under this strategy.
    /// @dev Contracts can choose to deploy an instance with a factory-model or handle all distributions within the
    /// implementing contract. For some strategies this function will handle the entire distribution, for others it
    /// could merely set up initial state and provide additional entrypoints to handle the distribution logic.
    /// @param token The token to distribute
    /// @param totalSupply The total supply of the token
    /// @param configData Arbitrary, strategy-specific parameters.
    /// @param salt The salt to use for the distribution
    function initializeDistribution(address token, uint128 totalSupply, bytes calldata configData, bytes32 salt)
        external;
}
