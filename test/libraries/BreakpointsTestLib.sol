// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ILBPStrategy} from "src/interfaces/ILBPStrategy.sol";

/// @title BreakpointsTestLib
/// @notice Test-only helper for packing LpAllocationBracket arrays into the wire format.
/// @dev Mirrors the off-chain encoding production callers do in their deploy scripts.
/// Each bracket is 35 bytes: 32 bytes lowerThreshold (uint256) || 3 bytes rate (uint24).
library BreakpointsTestLib {
    /// @notice Packs a typed bracket array into the canonical wire format
    /// @param brackets The typed bracket array
    /// @return encoded The packed bytes (brackets.length * 35 bytes)
    function encode(ILBPStrategy.LpAllocationBracket[] memory brackets) internal pure returns (bytes memory encoded) {
        uint256 n = brackets.length;
        for (uint256 i = 0; i < n; i++) {
            encoded = bytes.concat(encoded, abi.encodePacked(brackets[i].lowerThreshold, brackets[i].rate));
        }
    }
}
