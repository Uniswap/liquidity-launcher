// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title ILBPStrategyConfiguration
/// @notice Interface for the LBPStrategy configuration contract
interface ILBPStrategyConfiguration {
    /// @notice Emitted when the protocol fee controller is set
    /// @param protocolFeeController The protocol fee controller
    event ProtocolFeeControllerSet(address protocolFeeController);

    /// @notice Emitted when the min split for LP is set
    /// @param minSplitForLp The min split for LP
    event MinSplitForLpSet(uint24 minSplitForLp);

    /// @notice Error thrown when the protocol fee controller is the zero address
    error InvalidProtocolFeeController();

    /// @notice Error thrown when the min split for LP is zero or greater than 10_000
    error InvalidMinSplitForLp();

    /// @notice Sets the protocol fee controller
    /// @param protocolFeeController The protocol fee controller
    function setProtocolFeeController(address protocolFeeController) external;

    /// @notice Sets the min split for LP
    /// @param minSplitForLp The min split for LP
    function setMinSplitForLp(uint24 minSplitForLp) external;
}
