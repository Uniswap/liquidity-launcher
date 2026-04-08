// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IProtocolFeeController} from "../interfaces/IProtocolFeeController.sol";
import {Owned} from "@uniswap/v4-core/lib/solmate/src/auth/Owned.sol";

contract ProtocolFeeController is Owned, IProtocolFeeController {
    uint24 public constant BPS = 10_000;
    uint8 public constant UINT8_MASK = 0xff;
    uint16 public constant UINT16_MASK = 0xffff;
    uint24 public constant UINT24_MASK = 0xffffff;
    /// @notice bytes4(keccak256("CURRENCY_PROTOCOL_FEE"))
    bytes4 public constant CURRENCY_PROTOCOL_FEE_SLOT_PREFIX = 0x9562575e;

    GlobalFee public globalProtocolFee;

    event GlobalProtocolFeeSettingsUpdated(uint24 indexed globalProtocolFeeBps, address indexed recipient);
    event ProtocolFeePerCurrencyUpdated(address indexed currency, uint8 scale, Fee[] fees, uint16 cap);

    error InvalidFeeLength(uint8 length, uint8 maxLength);
    error InvalidScale(uint8 scale, uint8 maxScale);
    error InvalidInput();

    constructor() Owned(msg.sender) {}

    /// @inheritdoc IProtocolFeeController
    function setGlobalProtocolFeeSettings(uint24 globalProtocolFeeBps, address recipient) external onlyOwner {
        if (globalProtocolFeeBps > BPS) revert InvalidInput();
        if (recipient == address(0)) revert InvalidInput();

        GlobalFee memory globalProtocolFeeStruct =
            GlobalFee({globalProtocolFeeBps: globalProtocolFeeBps, globalProtocolFeeRecipient: recipient});

        globalProtocolFee = globalProtocolFeeStruct;
        emit GlobalProtocolFeeSettingsUpdated(globalProtocolFeeBps, recipient);
    }

    /// @inheritdoc IProtocolFeeController
    function setProtocolFeePerCurrency(address currency, uint8 scale, Fee[] calldata fees, uint16 cap)
        external
        onlyOwner
    {
        // If no fees are provided, delete the currency's custom protocol fee.
        if (fees.length == 0) {
            assembly ("memory-safe") {
                // Derive the slot and delete the currency's custom protocol fee.
                let slot := or(CURRENCY_PROTOCOL_FEE_SLOT_PREFIX, currency)
                sstore(slot, 0)
            }

            emit ProtocolFeePerCurrencyUpdated(currency, 0, fees, 0);
            return;
        }

        // Limit the number of fees gradations to 3
        if (fees.length > 3) revert InvalidFeeLength(uint8(fees.length), 3);
        // Scale is a power-of-10 exponent (threshold = startAmount * 10^scale).
        // Normally capped at 72 to prevent overflow: uint16 max (65,535) × 10^72 < uint256 max.
        // Tightened to 68 because the fee loop multiplies bracketAmount × feeBps (max 10,000):
        // 65,535 × 10^68 × 10,000 < uint256 max.
        if (scale > 68) revert InvalidScale(scale, 68);
        // The first fee gradation must start at 0, since it describes the base fee.
        if (fees[0].startAmount != 0) revert InvalidInput();

        // Use assembly to pack all fee gradations into a single slot
        assembly ("memory-safe") {
            // Custom protocol fees storage layout:
            // | 8 bits | 8 bits | 16 bits | 16 bits  | 16 bits | 16 bits  | 16 bits | 16 bits |
            // | length | scale  | fee1    | start2   | fee2    | start3   | fee3    | cap     |

            // Use errorBuffer to capture errors and revert if any are found.
            let errorBuffer := 0

            // Use previousStartAmount to ensure the startAmounts are in ascending order.
            let previousStartAmount := 0

            // Start at ptr 240. fees[0].startAmount is confirmed to be 0 and will be overwritten later by length & scale.
            let contentPtr := 240
            let content

            for { let i := 0 } lt(i, fees.length) { i := add(i, 1) } {
                let calldataPtr := add(fees.offset, mul(i, 0x40))
                let startAmount := and(calldataload(calldataPtr), UINT16_MASK) // sanitize the calldata
                let protocolFeeBps := and(calldataload(add(calldataPtr, 0x20)), UINT16_MASK) // sanitize the calldata

                // Ensure the protocolFeeBps is within bounds (max 10,000bps)
                errorBuffer := or(errorBuffer, gt(protocolFeeBps, BPS))
                // Ensure the startAmounts are in ascending order, though only if it's not the first fee gradation
                errorBuffer := or(errorBuffer, mul(i, iszero(gt(startAmount, previousStartAmount))))
                previousStartAmount := startAmount // cache the previous startAmount

                // Pack the startAmount into the content
                content := or(content, shl(contentPtr, startAmount))
                contentPtr := sub(contentPtr, 16) // safe because fees.length is limited to 3
                // Pack the protocolFeeBps valid for that startAmount into the content
                content := or(content, shl(contentPtr, protocolFeeBps))
                contentPtr := sub(contentPtr, 16) // safe because fees.length is limited to 3
            }
            // Ensure the cap is greater than the last startAmount or zero (indicating no cap set)
            errorBuffer := or(errorBuffer, and(iszero(gt(cap, previousStartAmount)), gt(cap, 0)))

            // Revert if any errors were found.
            if errorBuffer {
                mstore(0, 0xb4fa3fb3) // InvalidInput()
                revert(0x1c, 0x04)
            }
            // Pack the cap of after the fee gradations. Max of 65,535 fits into 16 bits.
            content := or(content, shl(contentPtr, and(cap, UINT16_MASK)))

            // Pack uint 8 length & uint8 scale. Overrides uint16 fees[0].startAmount, confirmed to be zero:
            // Pack the length of the fee gradations. Max length of three fits into 8 bits.
            content := or(content, shl(248, and(fees.length, UINT8_MASK)))
            // pack the scale of the fee gradations. Max of 68 fits into 8 bits.
            content := or(content, shl(240, and(scale, UINT8_MASK)))

            // Store the packed content in the currency's protocol fee slot.
            let slot := or(CURRENCY_PROTOCOL_FEE_SLOT_PREFIX, currency)
            sstore(slot, content)
        }
        emit ProtocolFeePerCurrencyUpdated(currency, scale, fees, cap);
    }

    /// @inheritdoc IProtocolFeeController
    function getProtocolFeeBps(address currency, uint256 amount)
        external
        view
        returns (uint24 protocolFeeBps, address protocolFeeRecipient)
    {
        if (amount == 0) {
            protocolFeeBps = 0;
            protocolFeeRecipient = globalProtocolFee.globalProtocolFeeRecipient;
            return (protocolFeeBps, protocolFeeRecipient);
        }
        uint256 protocolFeeAmount;
        (protocolFeeAmount, protocolFeeRecipient) = calculateProtocolFeeAmount(currency, amount);

        protocolFeeBps = uint24(protocolFeeAmount * BPS / amount);
    }

    /// @inheritdoc IProtocolFeeController
    function getProtocolFeeAmount(address currency, uint256 amount)
        public
        view
        returns (uint256 protocolFeeAmount, address protocolFeeRecipient)
    {
        if (amount == 0) {
            protocolFeeAmount = 0;
            protocolFeeRecipient = globalProtocolFee.globalProtocolFeeRecipient;
            return (protocolFeeAmount, protocolFeeRecipient);
        }
        (protocolFeeAmount, protocolFeeRecipient) = calculateProtocolFeeAmount(currency, amount);
    }

    /// @notice Calculates the protocol fee in basis points for the given currency and amount.
    ///         Honors custom protocol fee tiers and returns the global protocol fee if non was set.
    function calculateProtocolFeeAmount(address currency, uint256 amount)
        private
        view
        returns (uint256 protocolFeeAmount, address protocolFeeRecipient)
    {
        assembly ("memory-safe") {
            // Load the content of the global protocol fee slot.
            // Use assembly to directly cast the slot content to stack and skip memory allocation
            let globalContent := sload(globalProtocolFee.slot)
            // Get the global protocol fee basis points.
            let globalProtocolFeeBps := and(globalContent, UINT24_MASK)
            // Get the global protocol fee recipient.
            protocolFeeRecipient := shr(24, globalContent)

            // Custom protocol fees storage layout:
            // | 8 bits | 8 bits | 16 bits | 16 bits  | 16 bits | 16 bits  | 16 bits | 16 bits |
            // | length | scale  | fee1    | start2   | fee2    | start3   | fee3    | cap     |

            // Read the content of the currency's protocol fee slot.
            let slot := or(CURRENCY_PROTOCOL_FEE_SLOT_PREFIX, currency)
            let content := sload(slot)

            let length := shr(248, content)
            if length {
                // Custom protocol fees found.
                let scale := and(shr(240, content), UINT8_MASK)
                let scaleFactor := exp(10, scale)

                // Point to the first fee gradation (fee1).
                let contentPtr := 224
                let previousStartAmount := 0
                for { let i := 0 } lt(i, length) { i := add(i, 1) } {
                    // Retrieve the protocol fee basis points.
                    let protocolFeeBpsInBracket := and(shr(contentPtr, content), UINT16_MASK)
                    // Move the pointer to the next fee gradation start
                    contentPtr := sub(contentPtr, 16)
                    // Retrieve the next start amount or cap (ceiling of the current bracket).
                    let ceiling := and(shr(contentPtr, content), UINT16_MASK)
                    // Convert the ceiling to the scale factor.
                    ceiling := mul(ceiling, scaleFactor)
                    // Move the pointer to the next fee gradation protocol fee basis points
                    contentPtr := sub(contentPtr, 16)

                    // Determine if the amount is smaller than the ceiling, indicating the last bracket is reached.
                    // If the ceiling is zero (indicating the cap is reached and no cap set), use the amount as the ceiling.
                    let amountIsCeiling := or(gt(ceiling, amount), iszero(ceiling))
                    // If the amount is smaller than the ceiling, use the amount as the ceiling.
                    ceiling := or(mul(ceiling, iszero(amountIsCeiling)), mul(amount, amountIsCeiling))
                    // Calculate the amount of the current bracket.
                    let bracketAmount := sub(ceiling, previousStartAmount)
                    // Calculate the fee amount for the current bracket.
                    let feeOnBracket := div(mul(bracketAmount, protocolFeeBpsInBracket), BPS)
                    protocolFeeAmount := add(protocolFeeAmount, feeOnBracket)

                    if amountIsCeiling {
                        // The amount is less than the ceiling of the current bracket, no reason to continue.
                        break
                    }

                    previousStartAmount := ceiling
                }
            }

            // Use the global protocol fee, only if no custom protocol fees are configured.
            protocolFeeAmount := add(
                protocolFeeAmount,
                mul(div(mul(amount, globalProtocolFeeBps), BPS), iszero(length))
            )
        }
    }
}
