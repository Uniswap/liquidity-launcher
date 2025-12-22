// // SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title DynamicArray
/// @notice Library for building dynamic arrays
library DynamicArray {
    using DynamicArray for *;

    /// @notice Thrown when adding to the params array would exceed MAX_PARAMS_SIZE
    error LengthOverflow();
    /// @notice Thrown when trying to initlialize an already initialized params array
    error AlreadyInitialized();

    /// @notice Slot used to store the transient length of the params array
    /// @dev Calculated via: keccak256("ParamsBuilder.length")
    uint256 constant TRANSIENT_LENGTH_SLOT = 0x5be00963ec28506abc874f8add5a774bd4087736adfe0f8323b65472017fe098;

    /// @notice Maximum size of the params array
    /// @dev Supports full range (mint + settle + settle) and two one sided positions (mint + mint) and take pair
    uint256 constant MAX_PARAMS_SIZE = 6;

    /// @notice Transiently gets the actual length of the params array
    function getLength() internal view returns (uint256 length) {
        assembly {
            length := tload(TRANSIENT_LENGTH_SLOT)
        }
    }

    /// @notice Initializes the parameters, allocating memory for maximum number of params
    function init() internal returns (bytes[] memory params) {
        params = new bytes[](MAX_PARAMS_SIZE);
        assembly {
            if gt(tload(TRANSIENT_LENGTH_SLOT), 0) {
                mstore(0x00, 0x0dc149f0) // AlreadyInitialized() selector
                revert(0x1c, 0x04)
            }
            tstore(TRANSIENT_LENGTH_SLOT, 0)
        }
    }

    /// @notice Appends a parameter to the params array
    /// @param params The parameters array to append to
    /// @param param The parameter to append
    function append(bytes[] memory params, bytes memory param) internal returns (bytes[] memory) {
        assembly {
            let length := tload(TRANSIENT_LENGTH_SLOT)
            if eq(length, MAX_PARAMS_SIZE) {
                mstore(0x00, 0x8ecbb27e) // LengthOverflow() selector
                revert(0x1c, 0x04)
            }
            // Calculate slot: params + 0x20 (skip length) + length * 0x20
            let slot := add(add(params, 0x20), mul(length, 0x20))
            mstore(slot, param) // Store pointer to param
            tstore(TRANSIENT_LENGTH_SLOT, add(length, 1))
        }
        return params;
    }

    /// @notice Truncates parameters array to the actual length
    /// @param params The parameters to truncate
    function truncate(bytes[] memory params) internal view returns (bytes[] memory) {
        uint256 length = getLength();
        assembly {
            mstore(params, length)
        }
        return params;
    }
}
