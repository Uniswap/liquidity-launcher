// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IDistributionContract
/// @notice Interface for token distribution contracts.
interface IDistributionContract {
    /// @notice Notify a distribution contract that it has received the tokens to distribute
    /// @param token The address of the token to be distributed.
    /// @param amount The amount of tokens intended for distribution.
    function onTokensReceived(address token, uint256 amount) external;
}
