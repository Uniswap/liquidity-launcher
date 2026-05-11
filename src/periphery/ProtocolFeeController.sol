// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IProtocolFeeController} from "../interfaces/IProtocolFeeController.sol";
import {Ownable} from "solady/auth/Ownable.sol";

/// @title ProtocolFeeController
/// @notice Governance-controlled source of protocol fees for currency raised through token launches.
/// @custom:security-contact security@uniswap.org
contract ProtocolFeeController is Ownable, IProtocolFeeController {
    /// @notice The pips denominator (1,000,000 = 100%)
    uint24 public constant PIPS_DENOMINATOR = 1_000_000;
    /// @notice The maximum number of fee tiers per currency
    uint256 public constant MAX_FEES = 3;

    GlobalFee public globalProtocolFee;
    mapping(address currency => Fee[]) internal _currencyFees;

    constructor(address _owner) {
        _initializeOwner(_owner);
    }

    /// @inheritdoc IProtocolFeeController
    function setGlobalProtocolFeeSettings(uint24 globalProtocolFeePips, address recipient) external onlyOwner {
        if (globalProtocolFeePips > PIPS_DENOMINATOR) revert InvalidFeePips(globalProtocolFeePips, PIPS_DENOMINATOR);
        if (globalProtocolFeePips > 0 && recipient == address(0)) revert InvalidInput();

        globalProtocolFee =
            GlobalFee({globalProtocolFeePips: globalProtocolFeePips, globalProtocolFeeRecipient: recipient});
        emit GlobalProtocolFeeSettingsUpdated(globalProtocolFeePips, recipient);
    }

    /// @inheritdoc IProtocolFeeController
    function setProtocolFeePerCurrency(address currency, Fee[] calldata fees) external onlyOwner {
        delete _currencyFees[currency];

        if (fees.length == 0) {
            emit ProtocolFeePerCurrencyUpdated(currency, fees);
            return;
        }

        if (globalProtocolFee.globalProtocolFeeRecipient == address(0)) revert InvalidInput();
        if (fees.length > MAX_FEES) revert InvalidFeeLength(fees.length);

        uint128 prevThreshold;
        for (uint256 i; i < fees.length; ++i) {
            if (fees[i].protocolFeePips > PIPS_DENOMINATOR) {
                revert InvalidFeePips(fees[i].protocolFeePips, PIPS_DENOMINATOR);
            }

            // For non-last tiers, thresholds must be strictly ascending and non-zero
            if (i < fees.length - 1) {
                if (fees[i].threshold == 0 || fees[i].threshold <= prevThreshold) revert InvalidInput();
                prevThreshold = fees[i].threshold;
            }

            _currencyFees[currency].push(fees[i]);
        }

        emit ProtocolFeePerCurrencyUpdated(currency, fees);
    }

    /// @inheritdoc IProtocolFeeController
    function getCurrencyFees(address currency) external view returns (Fee[] memory) {
        return _currencyFees[currency];
    }

    /// @inheritdoc IProtocolFeeController
    function getProtocolFeeAmount(address currency, uint256 amount)
        public
        view
        returns (uint256 protocolFeeAmount, address protocolFeeRecipient)
    {
        if (amount == 0) return (0, globalProtocolFee.globalProtocolFeeRecipient);
        (protocolFeeAmount, protocolFeeRecipient) = _calculateProtocolFeeAmount(currency, amount);
    }

    /// @notice Calculates the protocol fee amount for a given currency and amount
    /// @param currency The currency address
    /// @param amount The amount denoted in currency
    /// @return protocolFeeAmount The protocol fee amount
    /// @return protocolFeeRecipient The address that should receive the fee
    function _calculateProtocolFeeAmount(address currency, uint256 amount)
        private
        view
        returns (uint256 protocolFeeAmount, address protocolFeeRecipient)
    {
        if (amount > type(uint256).max / PIPS_DENOMINATOR) amount = type(uint256).max / PIPS_DENOMINATOR;

        protocolFeeRecipient = globalProtocolFee.globalProtocolFeeRecipient;

        Fee[] storage fees = _currencyFees[currency];
        uint256 len = fees.length;

        if (len == 0) {
            protocolFeeAmount = amount * globalProtocolFee.globalProtocolFeePips / PIPS_DENOMINATOR;
            return (protocolFeeAmount, protocolFeeRecipient);
        }

        uint256 remaining = amount;
        uint256 prevThreshold;

        for (uint256 i; i < len; ++i) {
            if (i == len - 1) {
                // Last tier: its rate applies to all remaining amount
                protocolFeeAmount += remaining * fees[i].protocolFeePips / PIPS_DENOMINATOR;
                break;
            }

            uint256 bracketSize = uint256(fees[i].threshold) - prevThreshold;
            uint256 bracketAmount = remaining > bracketSize ? bracketSize : remaining;
            protocolFeeAmount += bracketAmount * fees[i].protocolFeePips / PIPS_DENOMINATOR;
            remaining -= bracketAmount;

            if (remaining == 0) break;
            prevThreshold = fees[i].threshold;
        }
    }
}
