// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IProtocolFeeController} from "src/interfaces/IProtocolFeeController.sol";

/// @notice Minimal mock that returns zero fees by default (fee off).
/// Tests can override the fee returned by `getProtocolFeeAmount` via `setMockFee`.
contract MockProtocolFeeController is IProtocolFeeController {
    GlobalFee public globalProtocolFee;

    uint256 internal _mockFeeAmount;
    address internal _mockFeeRecipient;

    function setMockFee(uint256 feeAmount, address feeRecipient) external {
        _mockFeeAmount = feeAmount;
        _mockFeeRecipient = feeRecipient;
    }

    function setGlobalProtocolFeeSettings(uint24 globalProtocolFeePips, address recipient) external {
        globalProtocolFee =
            GlobalFee({globalProtocolFeePips: globalProtocolFeePips, globalProtocolFeeRecipient: recipient});
        emit GlobalProtocolFeeSettingsUpdated(globalProtocolFeePips, recipient);
    }

    function setProtocolFeePerCurrency(address, Fee[] calldata) external {}

    function getProtocolFeeAmount(address, uint256) external view returns (uint256, address) {
        return (_mockFeeAmount, _mockFeeRecipient);
    }

    function getCurrencyFees(address) external pure returns (Fee[] memory) {
        return new Fee[](0);
    }
}
