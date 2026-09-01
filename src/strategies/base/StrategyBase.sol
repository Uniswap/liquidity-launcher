// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IV4FeeAdapter} from "../../interfaces/external/IV4FeeAdapter.sol";

/// @title StrategyBase
/// @notice Abstract base contract for all strategies
abstract contract StrategyBase {
    /// @notice The v4 pool manager.
    IPoolManager public immutable poolManager;

    /// @dev `IV4FeeAdapter.triggerFeeUpdate((address,address,uint24,int24,address))`
    bytes4 private constant _TRIGGER_FEE_UPDATE_SELECTOR = IV4FeeAdapter.triggerFeeUpdate.selector;

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    /// @notice Triggers a fee update for a single initialized pool
    /// @dev The IV4FeeAdapter silently skips uninitialized pools so this must be called after initialization
    /// @return success true if the fee update was successful. Implementing contracts can choose to revert on failure.
    /// @return data any return data from the fee controller
    function _handleFeeUpdate(PoolKey memory key) internal returns (bool success, bytes memory data) {
        address feeController = poolManager.protocolFeeController();
        // Skip if the fee controller is not set
        if (feeController == address(0)) return (false, "");
        (success, data) = feeController.call(abi.encodeWithSelector(_TRIGGER_FEE_UPDATE_SELECTOR, key));
    }
}
