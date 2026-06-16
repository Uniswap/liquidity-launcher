// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IProtocolFeeController
/// @notice Interface for the ProtocolFeeController, the governance-controlled contract that
///         determines the protocol fee applied to currency raised through token launches.
/// @dev Fee rates use pips (1 pip = 0.0001%, denominator 1,000,000)
///      Exposes a global flat fee used by default for all currencies, and an optional per-currency
///      override schedule with progressive tiers and an amount cap.
interface IProtocolFeeController {
    /// @notice A fee tier in a per-currency progressive fee schedule.
    ///         Tiers are sorted ascending by lowerThreshold. The first tier's lowerThreshold MUST be 0.
    ///         Each tier's rate applies to the portion of the amount in [lowerThreshold, nextLowerThreshold).
    ///         The last tier's rate applies to all remaining amount above its lowerThreshold.
    struct ProtocolFeeBracket {
        uint128 lowerThreshold; // lower bound of this bracket in cumulative currency amount (first tier must be 0). cumulative amounts above type(uint128).max are taxed at the last bracket's rate.
        uint24 protocolFeePips; // The fee rate in pips applied to the portion of the amount within this bracket
    }

    /// @notice Emitted when the protocol fee recipient is updated
    /// @param recipient The new recipient of all protocol fees (global and per-currency)
    event ProtocolFeeRecipientUpdated(address indexed recipient);

    /// @notice Emitted when the global protocol fee rate is updated
    /// @param globalProtocolFeePips The new global protocol fee in pips
    event GlobalProtocolFeePipsUpdated(uint24 indexed globalProtocolFeePips);

    /// @notice Emitted when a per-currency protocol fee schedule is set or cleared
    /// @param currency The currency the schedule applies to
    /// @param fees The tier schedule
    event ProtocolFeeBracketsForCurrencyUpdated(address indexed currency, ProtocolFeeBracket[] fees);

    /// @notice Thrown when the provided pips exceed the supported maximum (PIPS_DENOMINATOR)
    /// @param pips The provided pips
    /// @param maxPips The maximum supported pips
    error InvalidFeePips(uint24 pips, uint24 maxPips);

    /// @notice Thrown when the fee tier array exceeds the maximum length
    /// @param length The provided length
    error InvalidFeeLength(uint256 length);

    /// @notice Thrown when installing a per-currency fee schedule before a recipient is set
    error RecipientNotSet();

    /// @notice Thrown when the first tier's lowerThreshold is not zero
    /// @param lowerThreshold The provided first-tier lowerThreshold
    error FirstThresholdMustBeZero(uint128 lowerThreshold);

    /// @notice Thrown when a tier's lowerThreshold is not strictly greater than the previous tier's
    /// @param lowerThreshold The provided lowerThreshold
    /// @param prevLowerThreshold The previous tier's lowerThreshold
    error ThresholdsNotAscending(uint128 lowerThreshold, uint128 prevLowerThreshold);

    /// @notice Sets the recipient of all protocol fees (global and per-currency).
    /// @dev Recipient must be able to receive native ETH and ERC20 transfers. A recipient that
    ///      rejects transfers (including address(0)) will cause LBP migrations to revert until
    ///      governance sets a working recipient.
    /// @param recipient The address that receives protocol fees for all currencies
    function setProtocolFeeRecipient(address recipient) external;

    /// @notice Sets the global protocol fee rate, used as the fallback for currencies without a
    ///         per-currency tier schedule.
    /// @dev Per-currency schedules override this rate, but still pay to protocolFeeRecipient.
    /// @param globalProtocolFeePips The global protocol fee in pips
    function setGlobalProtocolFeePips(uint24 globalProtocolFeePips) external;

    /// @notice Sets a per-currency progressive fee schedule
    /// @dev The first tier's lowerThreshold must be 0; subsequent tiers must have strictly ascending lowerThresholds.
    ///      The last tier's rate applies to all remaining amount above its lowerThreshold.
    ///      Each tier's protocolFeePips must not exceed PIPS_DENOMINATOR.
    ///      Pass an empty fees array to clear the per-currency override and fall back to the global fee.
    /// @param currency The currency address the custom fees apply to
    /// @param fees The fee tiers, each with a lowerThreshold and fee rate in pips
    function setProtocolFeeBracketsForCurrency(address currency, ProtocolFeeBracket[] calldata fees) external;

    /// @notice Returns the fee tiers for a given currency
    /// @param currency The currency address
    /// @return fees The fee tiers
    function getProtocolFeeBracketsForCurrency(address currency)
        external
        view
        returns (ProtocolFeeBracket[] memory fees);

    /// @notice The address that receives all protocol fees (global and per-currency)
    function protocolFeeRecipient() external view returns (address);

    /// @notice Returns the protocol fee amount for a given currency and amount
    /// @dev If the currency has a per-currency tier schedule installed, the fee is computed
    ///      progressively across tiers. Otherwise the global pips rate is applied.
    /// @param currency The currency address
    /// @param amount The amount denoted in currency
    /// @return protocolFeeAmount The protocol fee amount
    function getProtocolFeeAmount(address currency, uint256 amount) external view returns (uint256 protocolFeeAmount);
}
