// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {InitializerHook} from "./InitializerHook.sol";

/// @title GatedSwapHook
/// @notice Hook that requires gatekeeper approval before swaps are allowed on the pool
contract GatedSwapHook is InitializerHook {
    /// @notice Emitted when swaps are approved by the gatekeeper
    event SwapsApproved();

    /// @notice Error thrown when a swap is attempted before approval
    error SwapsNotApproved();

    /// @notice Error thrown when a non-gatekeeper address attempts to approve swaps
    /// @param caller The address that attempted the call
    /// @param expected The gatekeeper address
    error NotGatekeeper(address caller, address expected);

    /// @notice The gatekeeper address that must approve swaps
    address public immutable gatekeeper;

    /// @notice Whether swaps have been approved by the gatekeeper
    bool public isApproved;

    constructor(IPoolManager _poolManager, address _strategy, address _gatekeeper)
        InitializerHook(_poolManager, _strategy)
    {
        gatekeeper = _gatekeeper;
    }

    /// @notice Approve swaps on the pool. Only callable by the gatekeeper.
    function approveSwaps() external {
        if (msg.sender != gatekeeper) revert NotGatekeeper(msg.sender, gatekeeper);
        isApproved = true;
        emit SwapsApproved();
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            beforeAddLiquidity: false,
            beforeSwap: true,
            beforeSwapReturnDelta: false,
            afterSwap: false,
            afterInitialize: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeDonate: false,
            afterDonate: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (!isApproved) revert SwapsNotApproved();
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
}
