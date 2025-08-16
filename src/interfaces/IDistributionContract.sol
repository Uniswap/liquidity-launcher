// SPDX-License-Identifier: UNLICENSED
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
    function onTokensReceived() external;
}
