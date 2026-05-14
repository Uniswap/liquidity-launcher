// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title SelfInitializerMixin
/// @notice Minimal mixin for hooks which only allow themselves to initialize pools
abstract contract SelfInitializerMixin {
    error OnlySelfCalls();

    constructor() {
        Hooks.Permissions memory permissions;
        permissions.beforeInitialize = true;
        Hooks.validateHookPermissions(IHooks(address(this)), permissions);
    }

    /// @notice Reverts any beforeInitialize callback
    /// @dev V4 skips beforeInitialize when sender == hook, so any callback is not a self-call.
    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert OnlySelfCalls();
    }
}
