// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

/// @title IClaimableRecipient
/// @notice Interface for position recipients that attribute received amounts to positions and hand
///         them to an `IClaimExecutor` callback on claim
interface IClaimableRecipient {
    /// @notice Thrown when the position does not exist or has been burned
    /// @param tokenId The invalid position token ID
    error InvalidPosition(uint256 tokenId);

    /// @notice Thrown when the position manager from a source is incompatible
    /// @param positionManager The incompatible position manager
    /// @param expectedPositionManager The expected position manager
    error InvalidPositionManager(IPositionManager positionManager, IPositionManager expectedPositionManager);

    /// @notice Thrown when the received amounts are less than expected
    /// @param currency The currency whose amount fell short
    /// @param received The amount actually available
    /// @param expected The amount required
    error InsufficientAmountReceived(Currency currency, uint256 received, uint256 expected);

    /// @notice Thrown when a transfer policy returns the zero address.
    /// @param currency The currency whose recipient is zero
    error InvalidTransferRecipient(Currency currency);

    /// @notice Emitted after a position's amounts are claimed and processed by an executor
    /// @param tokenId The claimed position
    /// @param currency0Amount The currency0 amount paid out
    /// @param currency1Amount The currency1 amount paid out
    /// @param poolKey The position's pool key
    event Claimed(uint256 indexed tokenId, uint256 currency0Amount, uint256 currency1Amount, PoolKey poolKey);

    /// @notice Emitted when received amounts are attributed to a position
    /// @param tokenId The position the amounts are attributed to
    /// @param currency0Amount The currency0 amount attributed
    /// @param currency1Amount The currency1 amount attributed
    event AmountsReceived(uint256 indexed tokenId, uint256 currency0Amount, uint256 currency1Amount);

    /// @notice Claims a position's attributed amounts; the payout is determined by the recipient's
    ///         transfer policy.
    /// @dev Amounts are transferred FIRST. Whether the caller is then called back through `onClaimed`
    ///      is fixed by the recipient's base, not by any runtime interface probe: recipients inheriting
    ///      `BaseClaimRecipientWithCallback` invoke it unconditionally, so their callers MUST implement
    ///      `IClaimExecutor`; recipients inheriting `BaseClaimRecipient` never call back.
    /// @param tokenId The token ID of the position
    /// @param minCurrency0Amount The minimum acceptable currency0 amount
    /// @param minCurrency1Amount The minimum acceptable currency1 amount
    function claim(uint256 tokenId, uint256 minCurrency0Amount, uint256 minCurrency1Amount) external;

    /// @notice Claims fees from a source for a given tokenId and accounts them to the canonical pool associated with the tokenId from the PositionManager
    /// @dev Only attributes to the canonical tokenId on PositionManager.
    ///      Source contracts MUST ensure that their internal tokenId accounting is 1:1 with the V4 LP NFT id, otherwise amounts received here will be lost.
    ///      Sources MUST pay out the full amount they report from `amounts`, so `currency1` MUST be a standard token that does not take a fee on transfer.
    /// @param _source The source to claim from
    /// @param _tokenId The token ID of the position
    /// @param _minCurrency0Amount The minimum acceptable currency0 amount
    /// @param _minCurrency1Amount The minimum acceptable currency1 amount
    function claimFrom(
        IClaimableRecipient _source,
        uint256 _tokenId,
        uint128 _minCurrency0Amount,
        uint128 _minCurrency1Amount
    ) external;

    /// @notice Returns the amounts attributed to a position and available to claim
    /// @param tokenId The position token ID
    /// @return currency0Amount The claimable currency0 amount
    /// @return currency1Amount The claimable currency1 amount
    function amounts(uint256 tokenId) external view returns (uint128 currency0Amount, uint128 currency1Amount);

    /// @notice The PositionManager that positions and their pool keys are resolved against.
    /// @return The recipient's PositionManager.
    function positionManager() external view returns (IPositionManager);

    /// @notice MUST be called after transferring amounts in to register the new balance. Failure to
    ///         do so will result in a loss of funds attribution.
    /// @dev Permissionless and balance-backed; the position's currencies are resolved from the
    ///      PositionManager, never from the caller. Implementations MUST NOT revert for a position they
    ///      serve: sources that push before notifying do not swallow it, so a revert reverts their call.
    /// @param tokenId The token ID of the position
    /// @param currency0Amount The amount of currency0 received
    /// @param currency1Amount The amount of currency1 received
    function onAmountsReceived(uint256 tokenId, uint256 currency0Amount, uint256 currency1Amount) external;
}
