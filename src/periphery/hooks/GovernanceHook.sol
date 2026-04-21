// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {LBPHookBase} from "./LBPHookBase.sol";

/// @title GovernanceHook
/// @notice Hook that requires governance approval before swaps are allowed on the pool
contract GovernanceHook is LBPHookBase {
    event SwapsApproved();

    /// @notice Error thrown when a swap is attempted before governance approval
    /// @param sender The address that attempted the swap
    error SwapsNotApproved(address sender);

    /// @notice Error thrown when a non-governance address attempts to approve swaps
    /// @param caller The address that attempted the call
    /// @param expected The governance address
    error NotGovernance(address caller, address expected);

    /// @notice The governance address that must approve swaps
    address public immutable governance;

    /// @notice Whether swaps have been approved by governance
    bool public isApproved;

    constructor(IPoolManager _poolManager, address _strategy, address _governance)
        LBPHookBase(_poolManager, _strategy)
    {
        governance = _governance;
    }

    /// @notice Approve swaps on the pool. Only callable by governance.
    function approveSwaps() external {
        if (msg.sender != governance) revert NotGovernance(msg.sender, governance);
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

    function _beforeSwap(address sender, PoolKey calldata, SwapParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (!isApproved) revert SwapsNotApproved(sender);
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
}
