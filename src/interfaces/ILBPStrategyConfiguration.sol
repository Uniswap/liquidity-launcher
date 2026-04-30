// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title ILBPStrategyConfiguration
/// @notice Interface for the LBPStrategy configuration contract
interface ILBPStrategyConfiguration {
    /// @notice Emitted when the protocol fee controller is set
    /// @param protocolFeeController The protocol fee controller
    event ProtocolFeeControllerSet(address protocolFeeController);

    /// @notice Emitted when the min bracket rate is set
    /// @param minBracketRate The min bracket rate
    event MinBracketRateSet(uint24 minBracketRate);

    /// @notice Error thrown when the protocol fee controller is the zero address
    error InvalidProtocolFeeController();

    /// @notice Error thrown when the min bracket rate is zero or greater than MAX_BRACKET_RATE
    /// @param minBracketRate The invalid min bracket rate
    error InvalidMinBracketRate(uint24 minBracketRate);

    /// @notice Error thrown when the breakpoints array length is invalid (empty or exceeds max)
    /// @param length The invalid breakpoints array length
    error InvalidBreakpointLength(uint256 length);

    /// @notice Error thrown when a breakpoint rate is outside [minBracketRate, MAX_BRACKET_RATE]
    /// @param rate The invalid breakpoint rate
    error InvalidBreakpointRate(uint24 rate);

    /// @notice Error thrown when a breakpoint threshold is zero or not strictly ascending
    /// @param threshold The invalid breakpoint threshold
    error InvalidBreakpointThreshold(uint128 threshold);

    /// @notice Sets the protocol fee controller
    /// @param protocolFeeController The protocol fee controller
    function setProtocolFeeController(address protocolFeeController) external;

    /// @notice Sets the min bracket rate
    /// @param minBracketRate The min bracket rate
    function setMinBracketRate(uint24 minBracketRate) external;
}
