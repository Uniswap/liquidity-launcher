// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IDistributionContract
/// @notice Interface for token distribution contracts.
/// @dev Distribution contracts are meant to be used with a push based token model: the caller sends token funds
///      first, then MUST call `onTokensReceived()` after sending the funds.
interface IDistributionContract {
    /// @notice Error thrown when the token address is invalid
    error InvalidToken(address token);

    /// @notice Error thrown when the amount received is invalid upon receiving tokens
    /// @param expected The expected amount
    /// @param received The received amount
    error InvalidAmountReceived(uint256 expected, uint256 received);

    /// @notice Notify a distribution contract that it has received the tokens to distribute.
    /// @dev MUST be called by the token sender after token funds are sent to the distribution contract.
    function onTokensReceived() external;
}
