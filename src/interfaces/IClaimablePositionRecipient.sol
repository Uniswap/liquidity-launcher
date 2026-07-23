// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title IClaimablePositionRecipient
/// @notice Interface for position recipients that attribute received amounts to positions and hand
///         them to an `IClaimExecutor` callback on claim
interface IClaimablePositionRecipient {
    /// @notice Thrown when the position does not exist or has been burned
    error InvalidPosition(uint256 tokenId);

    /// @notice Thrown when the received amounts are less than expected
    error InsufficientAmountReceived(Currency currency, uint256 received, uint256 expected);

    /// @notice Emitted after a position's amounts are claimed and processed by an executor
    event Claimed(uint256 indexed tokenId, uint256 currency0Amount, uint256 currency1Amount, PoolKey poolKey);

    /// @notice Claims a position's attributed amounts and lets the caller process them atomically
    /// @dev The caller must implement `IClaimExecutor` and is invoked with the claimed amounts
    /// @param tokenId The token ID of the position
    /// @param minCurrency0Amount The minimum acceptable currency0 amount
    /// @param minCurrency1Amount The minimum acceptable currency1 amount
    function claim(uint256 tokenId, uint256 minCurrency0Amount, uint256 minCurrency1Amount) external;

    /// @notice Returns the amounts attributed to a position and available to claim
    function amounts(uint256 tokenId) external view returns (uint256 currency0Amount, uint256 currency1Amount);

    /// @notice Called when amounts are received for a position
    /// @dev Permissionless and balance-backed. Any balance not already attributed can be attributed
    ///      by a caller, so funds should be transferred and notified atomically. The position's
    ///      currencies are resolved from the PositionManager, never from the caller.
    /// @param tokenId The token ID of the position
    /// @param currency0Amount The amount of currency0 received
    /// @param currency1Amount The amount of currency1 received
    function onAmountsReceived(uint256 tokenId, uint256 currency0Amount, uint256 currency1Amount) external;
}
