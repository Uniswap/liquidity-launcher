// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title ILPFeesPositionRecipient
/// @notice Interface for position recipients that collect LP fees and hand them to an `ILPFeesExecutor` callback
interface ILPFeesPositionRecipient {
    /// @notice Thrown when the position does not exist or has been burned
    error InvalidPosition(uint256 tokenId);

    /// @notice Thrown when the received amounts are less than expected
    error InsufficientAmountReceived(Currency currency, uint256 received, uint256 expected);

    /// @notice Thrown when notified about fees in a currency outside the position's pool
    error InvalidFeeCurrency(Currency currency);

    /// @notice Emitted after fees are collected and processed by an executor
    event FeesCollected(uint256 indexed tokenId, uint256 currency0Received, uint256 currency1Received, PoolKey poolKey);

    /// @notice Collects a position's fees and lets the caller process them atomically
    /// @dev The caller must implement `ILPFeesExecutor` and is invoked with the collected amounts
    /// @param tokenId The token ID of the position
    /// @param minCurrency0Amount The minimum acceptable currency0 fees
    /// @param minCurrency1Amount The minimum acceptable currency1 fees
    function collectFees(uint256 tokenId, uint256 minCurrency0Amount, uint256 minCurrency1Amount) external;

    /// @notice Returns the fees attributed to a position and available for collection
    function fees(uint256 tokenId) external view returns (uint256 currency0Fees, uint256 currency1Fees);

    /// @notice Called when fees are received from a position
    /// @param tokenId The token ID of the position
    /// @param currency The currency of the fees received
    /// @param amount The amount of fees received
    function onFeesReceived(uint256 tokenId, Currency currency, uint256 amount) external;
}
