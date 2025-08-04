// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {MigratorParameters} from "../types/MigratorParams.sol";

contract HookBasic is BaseHook {
    error Unauthorized();

    constructor(bytes memory configData) BaseHook(IPoolManager(_extractPoolManager(configData))) {}

    // Helper function to extract poolManager from configData
    function _extractPoolManager(bytes memory configData) private pure returns (IPoolManager) {
        (MigratorParameters memory parameters,) = abi.decode(configData, (MigratorParameters, bytes));
        return IPoolManager(parameters.poolManager);
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            beforeAddLiquidity: false,
            beforeSwap: false,
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

    function _beforeInitialize(address sender, PoolKey calldata, uint160) internal view override returns (bytes4) {
        if (sender != address(this)) revert Unauthorized();
        return IHooks.beforeInitialize.selector;
    }
}
