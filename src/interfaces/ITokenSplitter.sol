// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IStrategy} from "./IStrategy.sol";

/// @title ITokenSplitter
/// @notice Interface for the TokenSplitter strategy
interface ITokenSplitter is IStrategy {
    /// @notice A single recipient/amount pair for a split
    /// @param recipient The address that receives `amount` of the distributed token
    /// @param amount The amount of the distributed token to send to `recipient`
    struct Split {
        address recipient;
        uint256 amount;
    }

    /// @notice Emitted when a token is split across recipients
    /// @param token The token that was split
    /// @param totalSupply The total amount that was distributed
    /// @param recipients The number of recipients the token was split across
    event TokensSplit(address indexed token, uint256 totalSupply, uint256 recipients);

    /// @notice Thrown when no splits are provided
    error NoSplits();

    /// @notice Thrown when a split recipient is the zero address
    error ZeroRecipient();

    /// @notice Thrown when a split amount is zero
    error ZeroAmount();

    /// @notice Thrown when the sum of split amounts does not equal the distributed total supply
    /// @param distributed The sum of all split amounts
    /// @param totalSupply The amount the strategy was expected to distribute
    error InvalidSplit(uint256 distributed, uint256 totalSupply);
}
