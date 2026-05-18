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

    /// @notice Recipient of ALL protocol fees (both the global fallback and per-currency tier-derived).
    ///         Must be able to receive the currency transfers; a recipient that rejects transfers will cause LBP migrations to revert.
    address public protocolFeeRecipient;

    /// @notice Global protocol fee rate in pips, applied as the fallback for currencies without a per-currency tier schedule.
    ///         Per-currency schedules override this rate but still pay to protocolFeeRecipient.
    uint24 public globalProtocolFeePips;

    /// @notice Per-currency progressive fee schedule. Tiers in `FeeBracket[]` are stored in the order
    ///         supplied to `setProtocolFeeBracketsForCurrency`. An empty array means no per-currency override is set
    ///         and `globalProtocolFeePips` is used for this currency instead.
    mapping(address currency => FeeBracket[]) internal _protocolFeeBrackets;

    constructor(address _owner) {
        _initializeOwner(_owner);
    }

    /// @inheritdoc IProtocolFeeController
    /// @dev Recipient must be able to receive the currency transfers; a recipient that rejects the
    ///      transfers will cause LBP migrations to revert until its pointed elsewhere.
    function setProtocolFeeRecipient(address _recipient) external onlyOwner {
        protocolFeeRecipient = _recipient;
        emit ProtocolFeeRecipientUpdated(_recipient);
    }

    /// @inheritdoc IProtocolFeeController
    function setGlobalProtocolFeePips(uint24 _globalProtocolFeePips) external onlyOwner {
        if (_globalProtocolFeePips > PIPS_DENOMINATOR) revert InvalidFeePips(_globalProtocolFeePips, PIPS_DENOMINATOR);
        globalProtocolFeePips = _globalProtocolFeePips;
        emit GlobalProtocolFeePipsUpdated(_globalProtocolFeePips);
    }

    /// @inheritdoc IProtocolFeeController
    /// @dev Passing an empty FeeBracket[] deletes the per-currency schedule, reverting this currency to the global pips
    function setProtocolFeeBracketsForCurrency(address currency, FeeBracket[] calldata fees) external onlyOwner {
        delete _protocolFeeBrackets[currency];

        if (fees.length == 0) {
            emit ProtocolFeeBracketsForCurrencyUpdated(currency, fees);
            return;
        }

        // Per-currency tiers require a recipient
        if (protocolFeeRecipient == address(0)) revert RecipientNotSet();
        if (fees.length > MAX_PROTOCOL_FEE_TIERS) revert InvalidFeeLength(fees.length);

        uint128 prevLowerThreshold;
        for (uint256 i; i < fees.length; ++i) {
            if (fees[i].protocolFeePips > PIPS_DENOMINATOR) {
                revert InvalidFeePips(fees[i].protocolFeePips, PIPS_DENOMINATOR);
            }

            // First tier's lowerThreshold must be 0; subsequent lowerThresholds must be strictly ascending
            if (i == 0) {
                if (fees[i].lowerThreshold != 0) revert FirstThresholdMustBeZero(fees[i].lowerThreshold);
            } else {
                if (fees[i].lowerThreshold <= prevLowerThreshold) {
                    revert ThresholdsNotAscending(fees[i].lowerThreshold, prevLowerThreshold);
                }
            }
            prevLowerThreshold = fees[i].lowerThreshold;

            _protocolFeeBrackets[currency].push(fees[i]);
        }

        emit ProtocolFeeBracketsForCurrencyUpdated(currency, fees);
    }

    /// @inheritdoc IProtocolFeeController
    function getProtocolFeeBracketsForCurrency(address currency) external view returns (FeeBracket[] memory) {
        return _protocolFeeBrackets[currency];
    }

    /// @inheritdoc IProtocolFeeController
    function getProtocolFeeAmount(address currency, uint256 amount) external view returns (uint256 protocolFeeAmount) {
        FeeBracket[] storage fees = _protocolFeeBrackets[currency];
        uint256 len = fees.length;

        if (len == 0) {
            return FullMath.mulDiv(amount, globalProtocolFeePips, PIPS_DENOMINATOR);
        }

        uint256 remaining = amount;

        for (uint256 i; i < len; ++i) {
            if (i == len - 1) {
                // Last tier: its rate applies to all remaining amount
                protocolFeeAmount += FullMath.mulDiv(remaining, fees[i].protocolFeePips, PIPS_DENOMINATOR);
                break;
            }

            // Non-last tier covers [fees[i].lowerThreshold, fees[i+1].lowerThreshold).
            uint256 bracketSize = fees[i + 1].lowerThreshold - fees[i].lowerThreshold;
            uint256 bracketAmount = remaining > bracketSize ? bracketSize : remaining;
            protocolFeeAmount += FullMath.mulDiv(bracketAmount, fees[i].protocolFeePips, PIPS_DENOMINATOR);
            remaining -= bracketAmount;

            if (remaining == 0) break;
        }
    }
}
