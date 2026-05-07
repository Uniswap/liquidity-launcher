// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title BreakpointsLib
/// @notice Packed decoding for LP allocation brackets.
/// @dev Each bracket is 35 bytes: 32 bytes lowerThreshold (uint256) || 3 bytes rate (uint24).
/// Production callers encode the schedule off-chain; this library only handles the on-chain read path.
library BreakpointsLib {
    /// @notice Packed size of a single bracket in bytes
    uint256 internal constant BRACKET_SIZE = 35;

    /// @notice Error thrown when the encoded byte length is not a multiple of BRACKET_SIZE
    error InvalidEncodedLength(uint256 length);

    /// @notice Decodes how many brackets a packed allocation schedule contains. Reverts on malformed
    /// byte lengths (not a clean multiple of BRACKET_SIZE).
    /// @dev Empty input returns 0 without reverting
    /// @param encoded The packed bytes
    /// @return The number of brackets
    function bracketCount(bytes memory encoded) internal pure returns (uint256) {
        if (encoded.length % BRACKET_SIZE != 0) revert InvalidEncodedLength(encoded.length);
        return encoded.length / BRACKET_SIZE;
    }

    /// @notice Reads the i-th bracket from a packed encoding
    /// @dev Caller is responsible for bounds checking against bracketCount(encoded). The bracket spans
    /// 35 bytes which exceeds a single 32-byte mload, so two mloads are used: one for the uint256
    /// lowerThreshold (bytes 0-31) and one for the uint24 rate (bytes 32-34, top of the second word).
    /// @param encoded The packed bytes
    /// @param i The bracket index
    /// @return lowerThreshold The bracket's lower threshold
    /// @return rate The bracket's allocation rate
    function at(bytes memory encoded, uint256 i) internal pure returns (uint256 lowerThreshold, uint24 rate) {
        assembly {
            // bytes data starts at add(encoded, 32). i-th bracket starts at offset i*35.
            let bracketStart := add(add(encoded, 32), mul(i, 35))
            // First 32 bytes = lowerThreshold (uint256)
            lowerThreshold := mload(bracketStart)
            // Next 3 bytes = rate (top 24 bits of the second word)
            rate := and(shr(232, mload(add(bracketStart, 32))), 0xffffff)
        }
    }
}
