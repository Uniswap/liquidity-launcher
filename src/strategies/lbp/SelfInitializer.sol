// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title SelfInitializerMixin
/// @notice Minimal mixin for contracts which only allow themselves to initialize pools
/// @dev Does not require PoolManager constructor arguments for simplicity
abstract contract SelfInitializerMixin {
    constructor() {
        Hooks.Permissions memory permissions;
        permissions.beforeInitialize = true;
        Hooks.validateHookPermissions(IHooks(address(this)), permissions);
    }

    /// @notice Basic implementation of beforeInitialize
    /// @dev PoolManager does not allow self calls so this function is a no-op in the happy path
    /// @dev it will revert if any other caller attempts to initialize a pool with this contract as the hook
    /// @dev Additionally, `msg.sender` does not have to be restricted to PoolManager since beforeInitialize is a view
    function beforeInitialize(address sender, PoolKey calldata, uint160) external view returns (bytes4) {
        require(sender == address(this), "SelfInitializer: Only callable by self");
        return IHooks.beforeInitialize.selector;
    }
}
