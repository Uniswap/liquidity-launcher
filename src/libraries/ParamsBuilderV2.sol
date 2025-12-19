// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title ParamsBuilderV2
/// @notice Library for building position parameters, using transient storage for the length
library ParamsBuilderV2 {
    using ParamsBuilderV2 for bytes[];

    // keccak256("ParamsBuilderV2.length")
    uint256 constant LENGTH_SLOT = 0x459e104ef556d0580f187381981773d0447fdbbca325472288740d540c65960b;

    uint8 constant MAX_PARAMS = 24;

    error LengthOverflow();

    /// @notice Return the first byte of the parameters, which is the length
    function getLength() internal view returns (uint8 length) {
        assembly {
            length := tload(LENGTH_SLOT)
        }
    }

    function setLength(uint8 length) internal {
        assembly {
            tstore(LENGTH_SLOT, length)
        }
    }

    /// @notice Initializes the parameters, allocating memory for maximum number of params
    function init() internal returns (bytes[] memory params) {
        params = new bytes[](MAX_PARAMS);
        setLength(0);
    }

    /// @notice Append a parameter to the parameters
    function append(bytes[] memory params, bytes memory param) internal returns (bytes[] memory) {
        uint8 length = getLength();
        if (length >= MAX_PARAMS) {
            revert LengthOverflow();
        }
        // Assign at length since its 0 indexed
        params[length] = param;
        setLength(length + 1);
        return params;
    }

    /// @notice Merges another set of parameters to the end of the current parameters
    function merge(bytes[] memory params, bytes[] memory otherParams) internal returns (bytes[] memory) {
        uint8 length = getLength();
        uint256 addt = otherParams.length;
        if (addt > MAX_PARAMS - length) {
            revert LengthOverflow();
        }

        for (uint256 i = 0; i < addt; i++) {
            params[length++] = otherParams[i];
        }
        setLength(length);
        return params;
    }

    /// @notice Truncates the parameters to the length
    /// @dev this is a one-way operation and should only be used after all parameters have been appended
    function truncate(bytes[] memory params) internal view returns (bytes[] memory) {
        uint8 length = getLength();
        assembly {
            mstore(params, length)
        }
        return params;
    }
}
