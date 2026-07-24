// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Recorder for FeeSplitter fee callbacks.
contract MockFeesCallback {
    error FeesCallbackFailed();
    error NativeRejected();

    bool public revertFees;
    bool public rejectNative;
    uint256 public feesCalls;
    uint256 public lastFeesTokenId;
    uint256 public lastCurrency0Amount;
    uint256 public lastCurrency1Amount;

    function setRevertFees(bool value) external {
        revertFees = value;
    }

    function setRejectNative(bool value) external {
        rejectNative = value;
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
