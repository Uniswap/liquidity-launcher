// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

type POSMParams is bytes;

/// @title ParamsBuilderV2
/// @notice Library for building position parameters
library ParamsBuilderV2 {
    using ParamsBuilderV2 for POSMParams;

    uint8 constant MAX_PARAMS = type(uint8).max;

    error LengthOverflow();

    function pack(uint8 length, bytes[] memory params) internal pure returns (bytes memory) {
        return abi.encodePacked(length, params);
    }

    /// @notice Unpacks the parameters from the data
    /// @dev data is abi.encodePacked(length, params)
    function unpack(bytes memory data) internal pure returns (uint8 length, bytes[] memory params) {
        assembly {
            length := mload(add(data, 0x20))
            params := mload(add(data, 0x40))
        }
    }

    /// @notice Return the first byte of the parameters, which is the length
    function num(POSMParams params) internal pure returns (uint8 length) {
        assembly {
            length := mload(add(params, 0x20))
        }
    }

    /// @notice Initializes the parameters, allocating memory for maximum number of params    
    function init() internal pure returns (POSMParams) {
        return abi.encodePacked(0, new bytes(MAX_PARAMS));
    }

    /// @notice Append a parameter to the parameters
    function append(POSMParams params, bytes memory param) internal pure returns (POSMParams) {
        (uint8 length, bytes[] memory params) = params.unpack();
        if (length >= MAX_PARAMS) {
            revert LengthOverflow();
        }
        // Assign at length since its 0 indexed
        params[length] = param;
        return pack(length + 1, params);
    }
}