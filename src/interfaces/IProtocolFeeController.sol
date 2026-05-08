// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IProtocolFeeController
/// @notice Interface for the ProtocolFeeController, the governance-controlled contract that
///         determines the protocol fee applied to currency raised through token launches.
/// @dev Fee rates use pips (1 pip = 0.0001%, denominator 1,000,000)
///      Exposes a global flat fee used by default for all currencies, and an optional per-currency
///      override schedule with progressive tiers and an amount cap.
interface IProtocolFeeController {
    /// @notice The global fee settings applied to all currencies without a per-currency override
    struct GlobalFee {
        uint24 globalProtocolFeePips; // The global protocol fee in pips
        address globalProtocolFeeRecipient; // The address that receives protocol fees for all currencies
    }

    /// @notice A fee tier in a per-currency progressive fee schedule.
    ///         Tiers are sorted ascending by threshold. The last tier's threshold is
    ///         ignored — its rate applies to all remaining currency above the previous threshold.
    struct Fee {
        uint128 threshold; // upper bound of this bracket in cumulative currency amount (ignored for last tier)
        uint24 protocolFeePips; // The fee rate in pips applied to the portion of the amount within this bracket
    }

    /// @notice Emitted when the global protocol fee settings are updated
    /// @param globalProtocolFeePips The new global protocol fee in pips
    /// @param recipient The new recipient of the global protocol fee
    event GlobalProtocolFeeSettingsUpdated(uint24 indexed globalProtocolFeePips, address indexed recipient);

    /// @notice Emitted when a per-currency protocol fee schedule is set or cleared
    /// @param currency The currency the schedule applies to
    /// @param fees The tier schedule
    event ProtocolFeePerCurrencyUpdated(address indexed currency, Fee[] fees);

    /// @notice Thrown when the provided pips exceed the supported maximum (PIPS_DENOMINATOR)
    /// @param pips The provided pips
    /// @param maxPips The maximum supported pips
    error InvalidFeePips(uint24 pips, uint24 maxPips);

    /// @notice Thrown when the fee tier array exceeds the maximum length
    /// @param length The provided length
    error InvalidFeeLength(uint256 length);

    /// @notice Generic error thrown for invalid inputs
    error InvalidInput();

    /// @notice Sets the global protocol fee settings for all currencies without custom fees
    /// @dev When pips is 0, recipient may be address(0) to disable the global fee.
    ///      When pips is > 0, recipient must be non-zero.
    /// @param globalProtocolFeePips The global protocol fee in pips
    /// @param recipient The recipient of the global protocol fee
    function setGlobalProtocolFeeSettings(uint24 globalProtocolFeePips, address recipient) external;

    /// @notice Sets a per-currency progressive fee schedule
    /// @dev For non-last tiers, thresholds must be strictly ascending and non-zero.
    ///      The last tier's threshold is ignored — its rate applies to all remaining amount.
    ///      Each tier's protocolFeePips must not exceed PIPS_DENOMINATOR.
    ///      Pass an empty fees array to clear the per-currency override and fall back to the global fee.
    /// @param currency The currency address the custom fees apply to
    /// @param fees The fee tiers, each with a threshold (upper bound) and fee rate in pips
    function setProtocolFeePerCurrency(address currency, Fee[] calldata fees) external;

    /// @notice Returns the exact protocol fee amount for a given currency and amount
    /// @dev This is the source of truth for fee deduction. Individual rate parameters are bounded
    ///      by PIPS_DENOMINATOR (1,000,000 pips = 100%).
    /// @param currency The currency address, address(0) for native
    /// @param amount The amount denoted in currency
    /// @return protocolFeeAmount The exact fee amount to deduct
    /// @return protocolFeeRecipient The address that should receive the fee
    function getProtocolFeeAmount(address currency, uint256 amount)
        external
        view
        returns (uint256 protocolFeeAmount, address protocolFeeRecipient);

    /// @notice Returns the fee tiers for a given currency
    /// @param currency The currency address
    /// @return fees The fee tiers
    function getCurrencyFees(address currency) external view returns (Fee[] memory fees);
}
