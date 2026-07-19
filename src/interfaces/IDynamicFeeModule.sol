// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title IDynamicFeeModule
/// @notice Pluggable source of a launch pool's LP fee. The launch hook delegates the "what is the fee
///         right now" decision to a module at an address it stores per pool, so the fee curve can be
///         replaced with different logic without changing the hook.
interface IDynamicFeeModule {
    /// @notice Quotes the current LP fee for both swap directions, in pips.
    /// @param key The pool being swapped
    /// @return zeroForOneFee The fee for a zeroForOne swap
    /// @return oneForZeroFee The fee for a oneForZero swap
    function getFee(PoolKey calldata key) external view returns (uint24 zeroForOneFee, uint24 oneForZeroFee);
}
