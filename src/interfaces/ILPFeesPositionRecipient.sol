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

    /// @notice Thrown when a fee-transfer policy returns the zero address.
    error InvalidTransferRecipient(Currency currency);

    /// @notice Emitted after fees are collected and processed by an executor
    event FeesCollected(uint256 indexed tokenId, uint256 currency0Received, uint256 currency1Received, PoolKey poolKey);

    /// @notice Collects a position's attributed fees; the payout is determined by the recipient's
    ///         transfer policy.
    /// @dev Amounts are transferred FIRST, then contract callers are invoked via
    ///      `ILPFeesExecutor.onFeesCollected`; EOAs are not called back.
    /// @param tokenId The token ID of the position
    /// @param minCurrency0Amount The minimum acceptable currency0 fees
    /// @param minCurrency1Amount The minimum acceptable currency1 fees
    function collectFees(uint256 tokenId, uint256 minCurrency0Amount, uint256 minCurrency1Amount) external;

    /// @notice Returns the fees attributed to a position and available for collection
    function fees(uint256 tokenId) external view returns (uint256 currency0Fees, uint256 currency1Fees);

    /// @notice MUST be called after transferring fees in to register the new balance. Failure to do
    ///         so will result in a loss of funds attribution.
    /// @dev Permissionless and balance-backed; the position's currencies are resolved from the
    ///      PositionManager, never from the caller.
    /// @param tokenId The token ID of the position
    /// @param currency0Amount The amount of currency0 fees received
    /// @param currency1Amount The amount of currency1 fees received
    function onFeesReceived(uint256 tokenId, uint256 currency0Amount, uint256 currency1Amount) external;
}
