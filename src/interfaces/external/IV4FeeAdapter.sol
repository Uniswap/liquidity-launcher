// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title IV4FeeAdapter
/// @notice Minimal subset of the IV4FeeAdapter interface used by the ProtocolFeeController
interface IV4FeeAdapter {
    /// @notice Triggers a fee update for a single pool. Permissionless.
    /// @dev Silently skips uninitialized pools (sqrtPriceX96 == 0).
    /// @param key The pool key to update.
    function triggerFeeUpdate(PoolKey calldata key) external;
}
