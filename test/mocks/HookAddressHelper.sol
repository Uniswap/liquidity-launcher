// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title HookAddressHelper
/// @notice Helper library for deploying contracts at specific hook addresses in tests
library HookAddressHelper {
    uint160 constant HOOK_PERMISSION_COUNT = 14;
    uint160 internal constant CLEAR_ALL_HOOK_PERMISSIONS_MASK = ~uint160(0) << (HOOK_PERMISSION_COUNT);

    /// @notice Calculates the hook address with specific permission flags
    /// @param flags The hook permission flags to set (e.g., Hooks.BEFORE_INITIALIZE_FLAG)
    /// @return The address with the specified hook permissions
    function getHookAddress(uint160 flags) internal pure returns (address) {
        return address(uint160(uint256(type(uint160).max) & CLEAR_ALL_HOOK_PERMISSIONS_MASK | flags));
    }

    /// @notice Deploys a contract implementation and sets it up at a hook address
    /// @param vm The Forge VM instance
    /// @param impl The deployed implementation contract
    /// @param hookAddress The target hook address
    /// @param storageSlots Number of storage slots to copy (default: 10)
    function setupHookContract(Vm vm, address impl, address hookAddress, uint256 storageSlots)
        internal
        returns (address)
    {
        // Copy bytecode
        vm.etch(hookAddress, impl.code);

        // Copy storage slots
        for (uint256 i = 0; i < storageSlots; i++) {
            bytes32 value = vm.load(impl, bytes32(i));
            vm.store(hookAddress, bytes32(i), value);
        }

        return hookAddress;
    }

    /// @notice Updates the hook address in a PoolKey stored in a specific slot
    /// @param vm The Forge VM instance
    /// @param hookAddress The hook contract address
    /// @param newHookAddress The new hook address to set
    /// @param poolKeySlot The storage slot where the PoolKey is stored
    function updatePoolKeyHook(Vm vm, address hookAddress, address newHookAddress, uint256 poolKeySlot)
        internal
        returns (address)
    {
        bytes32 slotValue = vm.load(hookAddress, bytes32(poolKeySlot));
        // Clear the lower 20 bytes and set the new hooks address
        bytes32 updatedSlot = (slotValue & bytes32(uint256(0xFFFFFFFFFFFFFFFFFFFFFFFF) << 160))
            | bytes32(uint256(uint160(newHookAddress)));
        vm.store(hookAddress, bytes32(poolKeySlot), updatedSlot);

        return hookAddress;
    }
}
