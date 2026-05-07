// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title ILBPStrategyConfiguration
/// @notice Interface for the LBPStrategy configuration contract
interface ILBPStrategyConfiguration {
    /// @notice Emitted when the protocol fee controller is set
    /// @param protocolFeeController The protocol fee controller
    event ProtocolFeeControllerSet(address protocolFeeController);

    /// @notice Error thrown when the protocol fee controller is the zero address
    error InvalidProtocolFeeController();

    /// @notice Error thrown when the LP allocation schedule has an invalid number of brackets (empty or exceeds max)
    /// @param count The invalid bracket count
    error InvalidBracketCount(uint256 count);

    /// @notice Error thrown when a bracket rate is greater than MAX_BRACKET_RATE
    /// @param rate The invalid bracket rate
    error InvalidBracketRate(uint24 rate);

    /// @notice Error thrown when a bracket lowerThreshold is not strictly ascending vs the previous bracket
    /// @param lowerThreshold The invalid bracket lowerThreshold
    error InvalidBracketThreshold(uint256 lowerThreshold);

    /// @notice Sets the protocol fee controller
    /// @param protocolFeeController The protocol fee controller
    function setProtocolFeeController(address protocolFeeController) external;
}
