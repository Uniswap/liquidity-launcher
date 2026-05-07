// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IProtocolFeeController
/// @notice Interface for the ProtocolFeeController, the governance-controlled contract that
///         determines the protocol fee applied to currency raised through token launches.
/// @dev Exposes a global flat fee used by default for all currencies, and an optional per-currency
///      override schedule with up to 3 progressive tiers and an amount cap.
interface IProtocolFeeController {
    /// @notice The global fee settings applied to all currencies without a per-currency override
    /// @param globalProtocolFeeBps The global protocol fee in basis points
    /// @param globalProtocolFeeRecipient The address that receives protocol fees for all currencies
    struct GlobalFee {
        uint24 globalProtocolFeeBps;
        address globalProtocolFeeRecipient;
    }

    /// @notice A single tier in a per-currency progressive fee schedule
    /// @param startAmount The scaled start amount of the bracket (threshold = startAmount * 10^scale)
    /// @param protocolFeeBps The fee rate in basis points applied to the portion of the amount within this bracket
    struct Fee {
        uint16 startAmount;
        uint16 protocolFeeBps;
    }

    /// @notice Emitted when the global protocol fee settings are updated
    /// @param globalProtocolFeeBps The new global protocol fee in basis points
    /// @param recipient The new recipient of the global protocol fee
    event GlobalProtocolFeeSettingsUpdated(uint24 indexed globalProtocolFeeBps, address indexed recipient);

    /// @notice Emitted when a per-currency protocol fee schedule is set or cleared
    /// @param currency The currency the schedule applies to
    /// @param scale The power-of-10 exponent used to scale the tier start amounts and cap
    /// @param fees The tier schedule
    /// @param cap The amount cap (scaled by 10^scale) after which no additional fees are charged
    event ProtocolFeePerCurrencyUpdated(address indexed currency, uint8 scale, Fee[] fees, uint16 cap);

    /// @notice Thrown when the number of tiers exceeds the supported maximum
    /// @param length The provided number of tiers
    /// @param maxLength The maximum supported number of tiers
    error InvalidFeeLength(uint8 length, uint8 maxLength);

    /// @notice Thrown when the scale exceeds the supported maximum
    /// @param scale The provided scale
    /// @param maxScale The maximum supported scale
    error InvalidScale(uint8 scale, uint8 maxScale);

    /// @notice Thrown when the provided basis points exceed the supported maximum
    /// @param bps The provided basis points
    /// @param maxBps The maximum supported basis points
    error InvalidBps(uint24 bps, uint24 maxBps);

    /// @notice Thrown when the first tier's startAmount is not zero
    error InvalidStartAmount();

    /// @notice Generic error thrown for invalid inputs
    error InvalidInput();

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
