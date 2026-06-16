// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IProtocolFeeController} from "../interfaces/IProtocolFeeController.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title ProtocolFeeLib
/// @notice Library for contracts implementing protocol fees via ProtocolFeeController
library ProtocolFeeLib {
    /// @notice Emitted when the protocol fee is transferred
    /// @param currency The address of the currency of the protocol fee
    /// @param protocolFeeAmount The amount of the protocol fee
    event ProtocolFeeTransferred(address indexed currency, uint256 protocolFeeAmount);

    /// @notice Returns the protocol fee amount for a given currency and amount
    /// @dev Returns zero if the fee controller is not set
    /// @param protocolFeeController The protocol fee controller
    /// @param currency The address of the currency denomination of the protocol fee
    /// @param amount The amount of the currency to apply the fee on
    /// @return the protocol fee amount
    function getProtocolFeeAmount(IProtocolFeeController protocolFeeController, address currency, uint256 amount)
        internal
        view
        returns (uint256)
    {
        if (address(protocolFeeController) == address(0)) return 0;
        try protocolFeeController.getProtocolFeeAmount(currency, amount) returns (uint256 protocolFeeAmount) {
            return protocolFeeAmount;
        } catch {
            return 0;
        }
    }

    /// @notice Transfers the protocol fee amount to the protocol fee recipient
    /// @param protocolFeeController The protocol fee controller
    /// @param currency The address of the currency denomination of the protocol fee
    /// @param protocolFeeAmount The protocol fee amount
    function transferProtocolFee(
        IProtocolFeeController protocolFeeController,
        address currency,
        uint256 protocolFeeAmount
    ) internal {
        CurrencyLibrary.transfer(
            Currency.wrap(currency), protocolFeeController.protocolFeeRecipient(), protocolFeeAmount
        );
        emit ProtocolFeeTransferred(currency, protocolFeeAmount);
    }
}
