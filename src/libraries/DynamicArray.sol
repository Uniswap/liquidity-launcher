// // SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title DynamicArray
/// @notice Library for building dynamic byte arrays. Increase the `MAX_PARAMS_SIZE` to support more parameters.
library DynamicArray {
    /// @notice Error thrown when the array length overflows the maximum size
    error LengthOverflow();

    /// @notice The maximum number of parameters that can be stored in the array
    uint24 constant MAX_PARAMS_SIZE = 6;

    /// @notice Initializes a new array in memory with the maximum size
    function init() internal pure returns (bytes[] memory params) {
        params = new bytes[](MAX_PARAMS_SIZE);
        assembly {
            mstore(params, 0) // Set initial length to 0
        }
    }

    /// @notice Appends a new parameter to the array
    /// @param params The existing array created via `init`
    /// @param param The new parameter to append
    function append(bytes[] memory params, bytes memory param) internal pure returns (bytes[] memory) {
        assembly {
            // Always read length via assembly to avoid optimizer assumptions
            let length := mload(params)
            if iszero(lt(length, MAX_PARAMS_SIZE)) {
                mstore(0x00, 0x8ecbb27e) // LengthOverflow() selector
                revert(0x1c, 0x04)
            }
            let slot := add(add(params, 0x20), mul(length, 0x20))
            mstore(slot, param)
            mstore(params, add(length, 1)) // Increment length
        }
        return params;
    }
}
