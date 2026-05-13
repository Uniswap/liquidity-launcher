// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IProtocolFeeController} from "../interfaces/IProtocolFeeController.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Ownable} from "solady/auth/Ownable.sol";

/// @title ProtocolFeeController
/// @notice Governance-controlled source of protocol fees for currency raised through token launches.
/// @custom:security-contact security@uniswap.org
contract ProtocolFeeController is Ownable, IProtocolFeeController {
    /// @notice The pips denominator (1,000,000 = 100%)
    uint24 public constant PIPS_DENOMINATOR = 1_000_000;
    /// @notice The maximum number of protocol fee tiers per currency
    uint256 public constant MAX_PROTOCOL_FEE_TIERS = 3;

    GlobalFee public globalProtocolFee;
    mapping(address currency => Fee[]) internal _currencyFees;

    constructor(address _owner) {
        _initializeOwner(_owner);
    }

    /// @inheritdoc IProtocolFeeController
    /// @dev Setting recipient to address(0) is the global kill switch — it disables ALL fees
    ///      (global and per-currency) without erasing installed schedules. Restoring a non-zero
    ///      recipient reinstates them.
    function setGlobalProtocolFeeSettings(uint24 globalProtocolFeePips, address recipient) external onlyOwner {
        if (globalProtocolFeePips > PIPS_DENOMINATOR) revert InvalidFeePips(globalProtocolFeePips, PIPS_DENOMINATOR);
        // A non-zero fee rate needs somewhere to send it
        if (globalProtocolFeePips > 0 && recipient == address(0)) revert InvalidInput();

        globalProtocolFee =
            GlobalFee({globalProtocolFeePips: globalProtocolFeePips, globalProtocolFeeRecipient: recipient});
        emit GlobalProtocolFeeSettingsUpdated(globalProtocolFeePips, recipient);
    }

    /// @inheritdoc IProtocolFeeController
    /// @dev Passing an empty Fee[] deletes the per-currency schedule, reverting this currency to the global pips
    function setProtocolFeePerCurrency(address currency, Fee[] calldata fees) external onlyOwner {
        delete _currencyFees[currency];

        if (fees.length == 0) {
            emit ProtocolFeePerCurrencyUpdated(currency, fees);
            return;
        }

        // Per-currency tiers require a global recipient — it's the payee for the tier-derived fee.
        if (globalProtocolFee.globalProtocolFeeRecipient == address(0)) revert InvalidInput();
        if (fees.length > MAX_PROTOCOL_FEE_TIERS) revert InvalidFeeLength(fees.length);

        uint128 prevLowerThreshold;
        for (uint256 i; i < fees.length; ++i) {
            if (fees[i].protocolFeePips > PIPS_DENOMINATOR) {
                revert InvalidFeePips(fees[i].protocolFeePips, PIPS_DENOMINATOR);
            }

            // First tier's lowerThreshold must be 0; subsequent lowerThresholds must be strictly ascending
            if (i == 0) {
                if (fees[i].lowerThreshold != 0) revert InvalidInput();
            } else {
                if (fees[i].lowerThreshold <= prevLowerThreshold) revert InvalidInput();
            }
            prevLowerThreshold = fees[i].lowerThreshold;

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
        external
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
        protocolFeeRecipient = globalProtocolFee.globalProtocolFeeRecipient;
        // When the global recipient is unset, the fee is off for every currency,
        // even if a per-currency schedule was installed earlier.
        if (protocolFeeRecipient == address(0)) return (0, address(0));

        Fee[] storage fees = _currencyFees[currency];
        uint256 len = fees.length;

        if (len == 0) {
            protocolFeeAmount = FullMath.mulDiv(amount, globalProtocolFee.globalProtocolFeePips, PIPS_DENOMINATOR);
            return (protocolFeeAmount, protocolFeeRecipient);
        }

        uint256 remaining = amount;

        for (uint256 i; i < len; ++i) {
            if (i == len - 1) {
                // Last tier: its rate applies to all remaining amount
                protocolFeeAmount += FullMath.mulDiv(remaining, fees[i].protocolFeePips, PIPS_DENOMINATOR);
                break;
            }

            // Non-last tier covers [fees[i].lowerThreshold, fees[i+1].lowerThreshold)
            uint256 bracketSize = uint256(fees[i + 1].lowerThreshold) - uint256(fees[i].lowerThreshold);
            uint256 bracketAmount = remaining > bracketSize ? bracketSize : remaining;
            protocolFeeAmount += FullMath.mulDiv(bracketAmount, fees[i].protocolFeePips, PIPS_DENOMINATOR);
            remaining -= bracketAmount;

            if (remaining == 0) break;
        }
    }
}
