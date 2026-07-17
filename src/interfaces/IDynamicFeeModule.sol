// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title IDynamicFeeModule
/// @notice Quotes directional LP fees for launch pools
interface IDynamicFeeModule {
    /// @notice Quotes the LP fee override for both swap directions of a launch pool
    /// @dev The launch hook calls this function during pool initialization and each swap in the launch window.
    ///      A revert blocks initialization or the swap. Module state is available from `key.hooks`.
    /// @param key The pool being swapped
    /// @return zeroForOneFee The fee in pips for currency0 -> currency1 swaps
    /// @return oneForZeroFee The fee in pips for currency1 -> currency0 swaps
    function getFee(PoolKey calldata key) external view returns (uint24 zeroForOneFee, uint24 oneForZeroFee);
}
