// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

interface ITimelockedPositionRecipient {
    /// @notice Thrown when trying to approve the operator before the timelock period has passed
    error Timelocked();

    /// @notice Emitted when the operator is approved to transfer the position
    /// @param operator The configured operator
    event OperatorApproved(address indexed operator);

    /// @notice Approves the operator to transfer all v4 positions held by this contract
    /// @dev Can be called by anyone after the timelock period has passed
    function approveOperator() external;

    // Getters

    /// @notice The block number at which the operator will be approved to transfer the position
    function timelockBlockNumber() external view returns (uint256);
    /// @notice The operator that will be approved to transfer the position
    function operator() external view returns (address);
    /// @notice The canonical v4 position manager
    function positionManager() external view returns (IPositionManager);
}
