// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IStrategy
/// @notice Interface for token distribution strategies.
interface IStrategy {
    /// @notice Emitted when a distribution is initialized
    /// @param distributor The distributor that was created to handle or manage the distribution.
    /// @param token The token that is being distributed.
    /// @param totalSupply The supply of the token that is being distributed.
    event DistributionInitialized(address indexed distributor, address indexed token, uint256 totalSupply);

    /// @notice Error thrown when the amount to be distributed is invalid
    /// @param amount The invalid amount
    /// @param maxAmount The maximum valid amount to be distributed
    error InvalidAmount(uint256 amount, uint256 maxAmount);

    /// @notice Initialize a distribution of tokens under this strategy.
    /// @dev Contracts can choose to deploy an instance with a factory-model or handle all distributions within the
    /// implementing contract. For some strategies this function will handle the entire distribution, for others it
    /// could merely set up initial state and provide additional entrypoints to handle the distribution logic.
    /// The strategy is responsible for pulling `totalSupply` of `token` from `msg.sender`.
    /// Implementations that deploy or predict deterministic distributors MUST include `salt` in the
    /// address calculation so callers can domain-separate otherwise identical distributions.
    /// @param token The token that is being distributed.
    /// @param totalSupply The supply of the token that is being distributed.
    /// @param configData Arbitrary, strategy-specific parameters.
    /// @param salt The salt for deterministic deployment, if used by the strategy.
    function initializeDistribution(address token, uint256 totalSupply, bytes calldata configData, bytes32 salt)
        external;
}
