// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IProtocolFeeController} from "../interfaces/external/IProtocolFeeController.sol";
import {Owned} from "@uniswap/v4-core/lib/solmate/src/auth/Owned.sol";

contract ProtocolFeeController is Owned, IProtocolFeeController {
    struct GlobalFee {
        uint24 globalProtocolFeeBps;
        address globalProtocolFeeRecipient;
    }

    struct Fee {
        uint24 startBps;
        uint24 protocolFeeBps;
    }

    uint24 public constant BPS = 10_000;
    uint24 public constant UINT24_MASK = 0xffffff;
    /// @notice bytes4(keccak256("CURRENCY_PROTOCOL_FEE"))
    /// @dev  mapping(address currency => Fee[] currencyProtocolFees) public currencyProtocolFees;
    bytes4 public constant CURRENCY_PROTOCOL_FEE_SLOT_PREFIX = 0x9562575e;

    GlobalFee public globalProtocolFee;

    event ProtocolFeeRecipientUpdated(address indexed recipient);
    event ProtocolFeeGlobalUpdated(uint24 indexed globalProtocolFeeBps);

    error InvalidFeeLength();
    error InvalidInput();

    constructor() Owned(msg.sender) {}

    function setProtocolFeeGlobal(uint24 globalProtocolFeeBps) external onlyOwner {
        if (globalProtocolFeeBps > BPS) revert InvalidInput();

        globalProtocolFee.globalProtocolFeeBps = globalProtocolFeeBps;
        emit ProtocolFeeGlobalUpdated(globalProtocolFeeBps);
    }

    function setProtocolFeeRecipient(address recipient) external onlyOwner {
        if (recipient == address(0)) revert InvalidInput();

        globalProtocolFee.globalProtocolFeeRecipient = recipient;
        emit ProtocolFeeRecipientUpdated(recipient);
    }

    function setProtocolFeePerCurrency(address currency, Fee[] calldata fees) external onlyOwner {
        // Limit the number of fees to 5 to stay within the storage slot size
        if (fees.length > 5) revert InvalidFeeLength();
        if (fees[0].startBps != 0) revert InvalidInput();

        // Use assembly to pack all fee gradations into a single slot
        assembly {
            // content storage layout:
            // uint16 |  uint24    &      uint24    | ...
            // length | startBps   & protocolFeeBps | ...

            let contentPtr := 240
            let content := shl(contentPtr, fees.length)

            let errorBuffer := 0

            let previousStartBps := 0

            for { let i := 0 } lt(i, fees.length) { i := add(i, 1) } {
                let calldataPtr := add(fees.offset, mul(i, 0x40))
                let startBps := and(calldataload(calldataPtr), UINT24_MASK)
                let protocolFeeBps := and(calldataload(add(calldataPtr, 0x20)), UINT24_MASK)
                errorBuffer := or(errorBuffer, gt(startBps, BPS))
                errorBuffer := or(errorBuffer, gt(protocolFeeBps, BPS))
                errorBuffer := or(errorBuffer, lt(startBps, previousStartBps))
                previousStartBps := startBps

                contentPtr := sub(contentPtr, 24)
                content := or(content, shl(contentPtr, startBps))
                contentPtr := sub(contentPtr, 24)
                content := or(content, shl(contentPtr, protocolFeeBps))
            }

            if errorBuffer {
                mstore(0, 0xb4fa3fb3) // InvalidInput()
                revert(0x1c, 0x04)
            }

            let slot := or(CURRENCY_PROTOCOL_FEE_SLOT_PREFIX, currency)
            sstore(slot, content)
        }
    }

    function getProtocolFeeBps(address currency, uint256 amount)
        public
        view
        returns (uint24 protocolFeeBps, address protocolFeeRecipient)
    {
        // Safety net to avoid overflow. Never expected to meet under realistic horizons.
        if (amount > type(uint240).max) amount = type(uint240).max;

        assembly {
            let slot := or(CURRENCY_PROTOCOL_FEE_SLOT_PREFIX, currency)
            // load the content of the custom protocol fees slot
            let content := sload(slot)

            // content storage layout:
            // uint16 |  uint24    &      uint24    | ...
            // length | startBps   & protocolFeeBps | ...

            // Get the length of the fee gradations
            let length := shr(240, content)
            // Check for custom protocol fees of the given currency
            if length {
                // Custom protocol fees found

                // Calculate the amount scope in basis points - safe because amount is clamped to uint240.max
                let amountScopeBps := div(mul(amount, BPS), not(0))
                let contentPtr := 240

                protocolFeeBps := 0

                // Loop through the fee gradations
                for { let i := 0 } lt(i, length) { i := add(i, 1) } {
                    contentPtr := sub(contentPtr, 24)
                    let startBps := and(shr(contentPtr, content), UINT24_MASK)
                    contentPtr := sub(contentPtr, 24)
                    // Check if startBPS is greater then amountScopeBps, indicating the previous protocolFeeBps is the correct one
                    if gt(startBps, amountScopeBps) { break }
                    // Update the protocolFeeBps
                    protocolFeeBps := and(shr(contentPtr, content), UINT24_MASK)
                }
            }

            // load the content of the global protocol fees slot. Necessary even if custom protocol fees are present.
            let globalProtocolFeeContent := sload(globalProtocolFee.slot)
            // Get the global protocol fee in basis points from the global protocol fees slot
            let globalProtocolFeeBps := and(globalProtocolFeeContent, UINT24_MASK)
            // Get the global protocol fee recipient
            protocolFeeRecipient := shr(24, globalProtocolFeeContent)

            // If protocolFeeBps is 0 (no custom protocol fees found), use the global protocol fee in basis points
            protocolFeeBps := mul(iszero(protocolFeeBps), globalProtocolFeeBps)
        }
    }

    function getProtocolFeeAmount(address currency, uint256 amount)
        external
        view
        returns (uint256 protocolFeeAmount, address protocolFeeRecipient)
    {
        uint24 protocolFeeBps;
        (protocolFeeBps, protocolFeeRecipient) = getProtocolFeeBps(currency, amount);
        // Calculate the protocol fee amount
        protocolFeeAmount = (amount * protocolFeeBps) / BPS;

        return (protocolFeeAmount, protocolFeeRecipient);
    }
}
