// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IFeeSplitter} from "../../src/interfaces/IFeeSplitter.sol";
import {IPositionReceivedCallback} from "../../src/interfaces/IPositionReceivedCallback.sol";

/// @notice Recorder for FeeSplitter position and fee callbacks.
contract MockPositionCallbacks is IPositionReceivedCallback {
    error PositionCallbackFailed();
    error FeesCallbackFailed();
    error NativeRejected();

    bool public revertPosition;
    bool public revertFees;
    bool public rejectNative;
    bool public collectOnPosition;
    uint256 public positionCalls;
    uint256 public feesCalls;
    uint256 public lastPositionTokenId;
    address public lastPositionFrom;
    bytes public lastPositionData;
    uint256 public lastFeesTokenId;
    uint256 public lastCurrency0Amount;
    uint256 public lastCurrency1Amount;

    function setRevertPosition(bool value) external {
        revertPosition = value;
    }

    function setRevertFees(bool value) external {
        revertFees = value;
    }

    function setRejectNative(bool value) external {
        rejectNative = value;
    }

    function setCollectOnPosition(bool value) external {
        collectOnPosition = value;
    }

    function onPositionReceived(uint256 tokenId, address from, bytes calldata data) external override {
        if (revertPosition) revert PositionCallbackFailed();
        if (collectOnPosition) {
            uint256[] memory tokenIds = new uint256[](1);
            tokenIds[0] = tokenId;
            IFeeSplitter(msg.sender).collectFees(tokenIds);
        }
        positionCalls++;
        lastPositionTokenId = tokenId;
        lastPositionFrom = from;
        lastPositionData = data;
    }

    function onFeesReceived(uint256 tokenId, uint256 currency0Amount, uint256 currency1Amount) external {
        if (revertFees) revert FeesCallbackFailed();
        feesCalls++;
        lastFeesTokenId = tokenId;
        lastCurrency0Amount = currency0Amount;
        lastCurrency1Amount = currency1Amount;
    }

    receive() external payable {
        if (rejectNative) revert NativeRejected();
    }
}
