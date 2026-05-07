// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Proxy} from "@openzeppelin/contracts/proxy/Proxy.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

/// @title HookProxy
/// @notice Proxy contract for hooks that allows for dynamic hook selection
contract HookProxy is Proxy {
    address public immutable impl;
    address public immutable strategy;

    error InvalidImplementation();
    error InvalidStrategy();
    error InvalidInitializer(address sender, address strategy);

    constructor(address _impl, address _strategy) {
        require(_impl != address(0), InvalidImplementation());
        require(_strategy != address(0), InvalidStrategy());
        impl = _impl;
        strategy = _strategy;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    /// @notice Requires the sender to be the strategy and delegates to the impl
    function beforeInitialize(address sender, PoolKey calldata, uint160) external returns (bytes4) {
        if (sender != strategy) revert InvalidInitializer(sender, strategy);
        (, bytes memory data) = _implementation().staticcall(hex"c4e833ce"); // getHookPermissions()
        Hooks.Permissions memory permissions = abi.decode(data, (Hooks.Permissions));
        if (permissions.beforeInitialize) _fallback();
        else return IHooks.beforeInitialize.selector;
    }

    /// @notice Returns the union of hook permissions of the implementation and { beforeInitialize: true }
    function getHookPermissions() public view returns (Hooks.Permissions memory) {
        (bool success, bytes memory data) = _implementation().staticcall(hex"c4e833ce"); // getHookPermissions()
        if (!success) revert InvalidImplementation(); // revert on failure to block deployment of the hook proxy
        Hooks.Permissions memory permissions = abi.decode(data, (Hooks.Permissions));
        permissions.beforeInitialize = true;
        return permissions;
    }

    /// @inheritdoc Proxy
    function _implementation() internal view override returns (address) {
        return impl;
    }
}
