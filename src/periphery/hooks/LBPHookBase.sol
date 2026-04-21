// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";

/// @title LBPHookBase
/// @notice Base hook for LBP pools that ensures only the authorized strategy can initialize the pool
abstract contract LBPHookBase is BaseHook {
    /// @notice Error thrown when a non-strategy address attempts to initialize the pool
    /// @param caller The address that attempted to initialize
    /// @param expected The authorized strategy address
    error InvalidInitializer(address caller, address expected);

    /// @notice The LBP strategy contract authorized to initialize the pool
    address public immutable strategy;

    constructor(IPoolManager _poolManager, address _strategy) BaseHook(_poolManager) {
        strategy = _strategy;
    }

    /// @inheritdoc BaseHook
    function _beforeInitialize(address sender, PoolKey calldata, uint160) internal view override returns (bytes4) {
        if (sender != strategy) revert InvalidInitializer(sender, strategy);
        return IHooks.beforeInitialize.selector;
    }
}
