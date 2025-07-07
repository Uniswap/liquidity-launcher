// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title TransientStorage
/// @notice A library for managing transient storage operations
/// @dev Provides readable wrappers around tstore and tload assembly operations
library TransientStorage {
    /// @notice Store a uint256 value in transient storage
    /// @param slot The storage slot to write to
    /// @param value The value to store
    function tstore(uint256 slot, uint256 value) internal {
        assembly {
            tstore(slot, value)
        }
    }

    /// @notice Load a uint256 value from transient storage
    /// @param slot The storage slot to read from
    /// @return value The value stored at the slot
    function tload(uint256 slot) internal view returns (uint256 value) {
        assembly {
            value := tload(slot)
        }
    }

    /// @notice Store an address in transient storage
    /// @param slot The storage slot to write to
    /// @param addr The address to store
    function tstoreAddress(uint256 slot, address addr) internal {
        assembly {
            tstore(slot, addr)
        }
    }

    /// @notice Load an address from transient storage
    /// @param slot The storage slot to read from
    /// @return addr The address stored at the slot
    function tloadAddress(uint256 slot) internal view returns (address addr) {
        assembly {
            addr := tload(slot)
        }
    }
} 