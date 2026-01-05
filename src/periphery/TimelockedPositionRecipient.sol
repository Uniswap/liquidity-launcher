// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BlockNumberish} from "blocknumberish/src/BlockNumberish.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ITimelockedPositionRecipient} from "../interfaces/ITimelockedPositionRecipient.sol";

/// @title TimelockedPositionRecipient
/// @notice Utility contract for holding v4 LP positions until a timelock period has passed
contract TimelockedPositionRecipient is ITimelockedPositionRecipient, ReentrancyGuardTransient, BlockNumberish {
    /// @notice Thrown when this contract is not the owner of the position
    error NotPositionOwner();

    /// @notice The position manager that will be used to create the position
    IPositionManager public immutable positionManager;
    /// @notice The operator that will be approved to transfer the position
    address public immutable operator;
    /// @notice The block number at which the operator will be approved to transfer the position
    uint256 public immutable timelockBlockNumber;

    constructor(IPositionManager _positionManager, address _operator, uint256 _timelockBlockNumber) {
        positionManager = _positionManager;
        operator = _operator;
        timelockBlockNumber = _timelockBlockNumber;
    }

    /// @notice Reverts if this contract is not the owner of the position
    /// @param _tokenId the token ID of the position
    modifier requireOwned(uint256 _tokenId) {
        if (IERC721(address(positionManager)).ownerOf(_tokenId) != address(this)) revert NotPositionOwner();
        _;
    }

    /// @inheritdoc ITimelockedPositionRecipient
    function approveOperator() external {
        if (_getBlockNumberish() < timelockBlockNumber) revert Timelocked();

        IERC721(address(positionManager)).setApprovalForAll(operator, true);

        emit OperatorApproved(operator);
    }

    /// @notice Receive ETH
    receive() external payable {}
}
