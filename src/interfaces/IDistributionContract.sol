// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IDistributionContract
/// @notice Interface for token distribution contracts.
interface IDistributionContract {
    /// @notice Error thrown when the token addressis invalid upon receiving tokens
    error InvalidToken();
    /// @notice Error thrown when the amount does not match the total supply upon receiving tokens
    error IncorrectTokenSupply();
    /// @notice Error thrown when the amount received is invalid upon receiving tokens
    error InvalidAmountReceived();

    /// @notice Notify a distribution contract that it has received the tokens to distribute
    /// @param token The address of the token to be distributed.
    /// @param amount The amount of tokens intended for distribution.
    function onTokensReceived(address token, uint256 amount) external;
}
