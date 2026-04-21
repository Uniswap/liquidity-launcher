// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BlockNumberish} from "@uniswap/blocknumberish/src/BlockNumberish.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LBPHookBase} from "./LBPHookBase.sol";

/// @title TimelockHook
/// @notice Hook that prevents removing liquidity until a timelock period has passed after pool initialization
contract TimelockHook is LBPHookBase, BlockNumberish {
    /// @notice Error thrown when liquidity removal is attempted before the timelock expires
    /// @param unlockBlock The block number at which liquidity removal is allowed
    /// @param currentBlock The current block number
    error Timelocked(uint256 unlockBlock, uint256 currentBlock);

    /// @notice The number of blocks after initialization before liquidity can be removed
    uint256 public immutable timelockDuration;

    /// @notice The block number at which the pool was initialized (0 if not yet initialized)
    uint256 public initializedBlock;

    constructor(IPoolManager _poolManager, address _strategy, uint256 _timelockDuration)
        LBPHookBase(_poolManager, _strategy)
    {
        timelockDuration = _timelockDuration;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            beforeAddLiquidity: false,
            beforeSwap: false,
            beforeSwapReturnDelta: false,
            afterSwap: false,
            afterInitialize: true,
            beforeRemoveLiquidity: true,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeDonate: false,
            afterDonate: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _afterInitialize(address, PoolKey calldata, uint160, int24) internal override returns (bytes4) {
        initializedBlock = _getBlockNumberish();
        return IHooks.afterInitialize.selector;
    }

    function _beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4)
    {
        uint256 unlockBlock = initializedBlock + timelockDuration;
        if (_getBlockNumberish() < unlockBlock) {
            revert Timelocked(unlockBlock, _getBlockNumberish());
        }
        return IHooks.beforeRemoveLiquidity.selector;
    }
}
