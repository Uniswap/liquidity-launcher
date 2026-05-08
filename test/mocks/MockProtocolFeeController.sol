// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IProtocolFeeController} from "src/interfaces/IProtocolFeeController.sol";

/// @notice Minimal mock that returns zero fees by default (fee off)
contract MockProtocolFeeController is IProtocolFeeController {
    GlobalFee public globalProtocolFee;

    function setGlobalProtocolFeeSettings(uint24 globalProtocolFeePips, address recipient) external {
        globalProtocolFee =
            GlobalFee({globalProtocolFeePips: globalProtocolFeePips, globalProtocolFeeRecipient: recipient});
        emit GlobalProtocolFeeSettingsUpdated(globalProtocolFeePips, recipient);
    }

    function setProtocolFeePerCurrency(address, Fee[] calldata) external {}

    function getProtocolFeeAmount(address, uint256) external pure returns (uint256, address) {
        return (0, address(0));
    }

    function getCurrencyFees(address) external pure returns (Fee[] memory) {
        return new Fee[](0);
    }
}
