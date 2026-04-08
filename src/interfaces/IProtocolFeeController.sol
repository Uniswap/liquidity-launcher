// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IProtocolFeeController
interface IProtocolFeeController {
    struct GlobalFee {
        uint24 globalProtocolFeeBps;
        address globalProtocolFeeRecipient;
    }

    struct Fee {
        uint16 startAmount;
        uint16 protocolFeeBps;
    }

    /// @notice Sets the global protocol fee settings for all currencies without custom fees
    /// @param globalProtocolFeeBps The global protocol fee in basis points
    /// @param recipient The recipient of the global protocol fee
    function setGlobalProtocolFeeSettings(uint24 globalProtocolFeeBps, address recipient) external;

    /// @notice Sets the protocol fee per currency
    /// @dev Must only be called after a global fee recipient is set.
    ///      Scale could match the currency's decimals, but it's not required and depends on the fee tier range.
    ///      Very low scales (< 4) cause bps rounding to undercount fees.
    /// @param currency The currency address the custom fees apply to
    /// @param scale The scale of the fee (protocolFeeBps * 10^scale)
    /// @param fees The fees, including the start amount for the bracket and the protocol fee in basis points (limited to 3 tiers)
    /// @param cap The amount cap (scaled by 10^scale) after which no additional fees are charged, 0 means no cap
    function setProtocolFeePerCurrency(address currency, uint8 scale, Fee[] calldata fees, uint16 cap) external;

    /// @notice Returns the protocol fee in basis points.
    ///         The bps are truncated to the nearest integer and the actual fee amount might slightly differ (within 1 BPS)
    /// @param currency The currency address, address(0) for native
    /// @param amount The amount denoted in currency
    function getProtocolFeeBps(address currency, uint256 amount)
        external
        view
        returns (uint24 protocolFeeBps, address protocolFeeRecipient);

    /// @notice Returns the exact protocol fee amount computed under the configured global or per-currency schedule.
    ///         This is the source of truth for fee deduction. Individual rate parameters are bounded by BPS (10,000 bps = 100%).
    /// @param currency The currency address, address(0) for native
    /// @param amount The amount denoted in currency
    function getProtocolFeeAmount(address currency, uint256 amount)
        external
        view
        returns (uint256 protocolFeeAmount, address protocolFeeRecipient);
}
