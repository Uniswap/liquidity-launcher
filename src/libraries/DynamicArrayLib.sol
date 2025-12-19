// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title DynamicArrayLib
/// @notice Library for dynamically building position parameters. Uses transient storage and truncates unused elements.
library DynamicArrayLib {
    using DynamicArrayLib for bytes[];

    /// @dev Slot for the length of the parameters in transient storage: `keccak256("DynamicArrayLib.length")`
    uint256 constant LENGTH_SLOT = 0x459e104ef556d0580f187381981773d0447fdbbca325472288740d540c65960b;

    /// @notice Maximum number of parameters allowed to prevent expensive memory expansion
    uint8 constant MAX_PARAMS = 24;

    /// @notice Error thrown when the number of parameters exceeds the maximum allowed
    error LengthOverflow();
    error AlreadyInitialized();

    /// @notice Getter function for the current length from transient storage
    function getLength() internal view returns (uint8 length) {
        assembly {
            length := tload(LENGTH_SLOT)
        }
    }

    /// @notice Initializes the parameters, allocating memory for maximum number of params
    function init() internal returns (bytes[] memory params) {
        params = new bytes[](MAX_PARAMS);
        assembly {
            if gt(tload(LENGTH_SLOT), 0) {
                mstore(0x00, 0x0dc149f0) // AlreadyInitialized() selector
                revert(0x1c, 0x04)
            }
            tstore(LENGTH_SLOT, 0)
        }
    }

    /// @notice Append a parameter to existing params
    /// @dev Using `merge` is more gas efficient for appending multiple values at once
    /// @param params The existing parameters. MUST be initialized via DynamicArrayLib.init()
    /// @param param The parameter to append
    /// @return The appended parameters
    function append(bytes[] memory params, bytes memory param) internal returns (bytes[] memory) {
        assembly {
            let length := tload(LENGTH_SLOT)
            if eq(length, MAX_PARAMS) {
                mstore(0x00, 0x8ecbb27e) // LengthOverflow() selector
                revert(0x1c, 0x04)
            }
            // Calculate slot: params + 0x20 (skip length) + length * 0x20
            let slot := add(add(params, 0x20), mul(length, 0x20))
            mstore(slot, param) // Store pointer to param
            tstore(LENGTH_SLOT, add(length, 1))
        }
        return params;
    }

    /// @notice Merges another set of parameters to the end of the current parameters
    /// @param params The existing parameters. MUST be initialized via DynamicArrayLib.init()
    /// @param otherParams The parameters to merge. CAN be any bytes[] array.
    /// @return The merged parameters
    function merge(bytes[] memory params, bytes[] memory otherParams) internal returns (bytes[] memory) {
        assembly {
            let length := tload(LENGTH_SLOT)
            let addt := mload(otherParams) // Get length of otherParams
            if gt(addt, sub(MAX_PARAMS, length)) {
                mstore(0x00, 0x8ecbb27e) // LengthOverflow() selector
                revert(0x1c, 0x04)
            }
            // Skip array length fields to get to data
            let paramsPtr := add(params, 0x20)
            let otherPtr := add(otherParams, 0x20)
            // Copy all pointers from otherParams to params
            for { let i := 0 } lt(i, addt) { i := add(i, 1) } {
                let destSlot := add(paramsPtr, mul(length, 0x20))
                let srcSlot := add(otherPtr, mul(i, 0x20))
                mstore(destSlot, mload(srcSlot))
                length := add(length, 1)
            }
            tstore(LENGTH_SLOT, length)
        }
        return params;
    }

    /// @notice Truncates the parameters to the length
    /// @dev This is a one-way operation and should only be used after all parameters have been appended
    /// @param params The existing parameters
    /// @return The truncated parameters
    function truncate(bytes[] memory params) internal view returns (bytes[] memory) {
        assembly {
            let length := tload(LENGTH_SLOT)
            mstore(params, length) // Overwrite array length in memory
        }
        return params;
    }
}
