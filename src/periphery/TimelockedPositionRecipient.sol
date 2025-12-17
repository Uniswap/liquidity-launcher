// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {IERC721} from "../interfaces/external/IERC721.sol";
import {ITimelockedPositionRecipient} from "../interfaces/ITimelockedPositionRecipient.sol";

/// @title TimelockedPositionRecipient
/// @notice Utility contract for holding v4 LP positions until a timelock period has passed
contract TimelockedPositionRecipient is ITimelockedPositionRecipient, ReentrancyGuardTransient {
    /// @notice The position manager that will be used to create the position
    IPositionManager public immutable POSITION_MANAGER;
    /// @notice The operator that will be approved to transfer the position
    address public immutable OPERATOR;
    /// @notice The block number at which the operator will be approved to transfer the position
    uint256 public immutable TIMELOCK_BLOCK_NUMBER;

    constructor(IPositionManager positionManager, address operator, uint256 timelockBlockNumber) {
        POSITION_MANAGER = positionManager;
        OPERATOR = operator;
        TIMELOCK_BLOCK_NUMBER = timelockBlockNumber;
    }

    /// @inheritdoc ITimelockedPositionRecipient
    function approveOperator() external {
        if (block.number < TIMELOCK_BLOCK_NUMBER) revert Timelocked();

        IERC721(address(POSITION_MANAGER)).setApprovalForAll(OPERATOR, true);

        emit OperatorApproved(OPERATOR);
    }

    /// @notice Receive ETH
    receive() external payable {}
}
