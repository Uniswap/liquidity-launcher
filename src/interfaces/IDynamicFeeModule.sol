// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title IDynamicFeeModule
/// @notice Interface for launch-window fee modules consulted by a launch hook
interface IDynamicFeeModule {
    /// @notice Quotes the LP fee override for both swap directions of a launch pool
    /// @dev Called by the hook via staticcall on every swap inside the launch window. A revert blocks the
    ///      swap until the window ends. Window state and module parameters are readable from the hook at
    ///      `key.hooks` via ILaunchHook.launchConfig.
    /// @param key The pool being swapped
    /// @return zeroForOneFee The fee in pips for currency0 -> currency1 swaps
    /// @return oneForZeroFee The fee in pips for currency1 -> currency0 swaps
    function getFee(PoolKey calldata key) external view returns (uint24 zeroForOneFee, uint24 oneForZeroFee);
}
