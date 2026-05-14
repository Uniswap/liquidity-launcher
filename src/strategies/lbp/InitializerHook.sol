// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title InitializerHook
/// @notice Minimal hook for contracts that initialize pools through self-calls
/// @dev Does not require PoolManager constructor arguments for simplicity
abstract contract InitializerHook {
    error OnlySelfCalls();

    constructor() {
        Hooks.Permissions memory permissions;
        permissions.beforeInitialize = true;
        Hooks.validateHookPermissions(IHooks(address(this)), permissions);
    }

    /// @notice Reverts any delivered beforeInitialize callback
    /// @dev V4 skips beforeInitialize when sender == hook, so any delivered callback is not a self-call.
    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert OnlySelfCalls();
    }
}
