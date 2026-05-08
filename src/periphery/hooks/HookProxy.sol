// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Proxy} from "@openzeppelin/contracts/proxy/Proxy.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

library HookProxyLib {
    error InvalidImplementation();

    /// @notice Deploys a hook proxy for a given implementation and salt
    /// @param _impl The implementation address
    /// @param _salt The salt to use for the deployment
    /// @return The address of the deployed hook proxy
    function deploy(address _impl, bytes32 _salt) internal returns (address) {
        return Create2.deploy(0, _salt, abi.encodePacked(type(HookProxy).creationCode, abi.encode(_impl)));
    }

    /// @notice Validates that the hook proxy will be deployed with the correct permissions
    /// @dev Supports the zero address and reverts if the salt does not produce an address with the correct bits
    /// @param _impl The implementation address
    /// @param _salt The salt to use for the deployment
    function preflight(address _impl, bytes32 _salt) internal view {
        Hooks.validateHookPermissions(
            IHooks(computeHookProxyAddress(_impl, _salt)),
            toPermissions((uint160(address(_impl)) & Hooks.ALL_HOOK_MASK) | Hooks.BEFORE_INITIALIZE_FLAG)
        );
    }

    /// @notice Computes the address of a hook proxy for a given implementation and salt
    function computeHookProxyAddress(address _impl, bytes32 _salt) internal view returns (address) {
        return
            Create2.computeAddress(_salt, keccak256(abi.encodePacked(type(HookProxy).creationCode, abi.encode(_impl))));
    }

    /// @notice Converts a uint160 flags to a Hooks.Permissions struct
    function toPermissions(uint160 flags) internal pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: flags & Hooks.BEFORE_INITIALIZE_FLAG != 0,
            afterInitialize: flags & Hooks.AFTER_INITIALIZE_FLAG != 0,
            beforeAddLiquidity: flags & Hooks.BEFORE_ADD_LIQUIDITY_FLAG != 0,
            afterAddLiquidity: flags & Hooks.AFTER_ADD_LIQUIDITY_FLAG != 0,
            beforeRemoveLiquidity: flags & Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG != 0,
            afterRemoveLiquidity: flags & Hooks.AFTER_REMOVE_LIQUIDITY_FLAG != 0,
            beforeSwap: flags & Hooks.BEFORE_SWAP_FLAG != 0,
            afterSwap: flags & Hooks.AFTER_SWAP_FLAG != 0,
            beforeDonate: flags & Hooks.BEFORE_DONATE_FLAG != 0,
            afterDonate: flags & Hooks.AFTER_DONATE_FLAG != 0,
            beforeSwapReturnDelta: flags & Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG != 0,
            afterSwapReturnDelta: flags & Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG != 0,
            afterAddLiquidityReturnDelta: flags & Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG != 0,
            afterRemoveLiquidityReturnDelta: flags & Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG != 0
        });
    }
}

/// @title HookProxy
/// @notice Minimal pass through proxy for hooks which prevent pool initialization frontrunning
/// @dev This hook MUST be deployed with all permissions set in the implementation AND beforeInitialize
contract HookProxy is Proxy {
    IHooks public immutable impl;
    address public immutable allowedInitializer;

    error InvalidImplementation();
    error InvalidInitializer(address sender, address allowedInitializer);

    constructor(IHooks _impl) {
        impl = _impl;
        allowedInitializer = msg.sender;
        Hooks.validateHookPermissions(
            IHooks(address(this)),
            HookProxyLib.toPermissions((uint160(address(impl)) & Hooks.ALL_HOOK_MASK) | Hooks.BEFORE_INITIALIZE_FLAG)
        );
    }

    /// @notice Requires the sender to be the strategy and delegates to the impl
    function beforeInitialize(address sender, PoolKey calldata, uint160) external returns (bytes4) {
        if (sender != allowedInitializer) revert InvalidInitializer(sender, allowedInitializer);
        // proxy the call to the implementation if it has beforeInitialize
        if (Hooks.hasPermission(impl, Hooks.BEFORE_INITIALIZE_FLAG)) _fallback();
        else return IHooks.beforeInitialize.selector;
    }

    /// @inheritdoc Proxy
    function _implementation() internal view override returns (address) {
        return address(impl);
    }
}
