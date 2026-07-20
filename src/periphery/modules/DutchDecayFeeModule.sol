// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BlockNumberish} from "@uniswap/blocknumberish/src/BlockNumberish.sol";
import {IDynamicFeeModule} from "../../interfaces/IDynamicFeeModule.sol";
import {IBondingCurveLaunchHook} from "../../interfaces/IBondingCurveLaunchHook.sol";

/// @title DutchDecayFeeModule
/// @notice Linearly decays a launch pool's LP fee from `startFee` to `endFee` over `decayBlocks` blocks,
///         anchored on the pool's `swapStartBlock`. Its parameters are fixed at deployment; to change the
///         fee curve, deploy a different module and point the strategy at it.
/// @dev Reads only the per-pool `swapStartBlock` from the launch hook; all fee parameters are immutable here.
contract DutchDecayFeeModule is IDynamicFeeModule, BlockNumberish {
    /// @notice Fee in pips at `swapStartBlock`.
    uint24 public immutable startFee;
    /// @notice Fee in pips once `decayBlocks` have elapsed.
    uint24 public immutable endFee;
    /// @notice Number of blocks over which the fee interpolates from `startFee` to `endFee`.
    uint48 public immutable decayBlocks;
    /// @notice When false, only token buys pay the decaying fee; token sells pay `endFee`.
    bool public immutable taxBothDirections;

    constructor(uint24 _startFee, uint24 _endFee, uint48 _decayBlocks, bool _taxBothDirections) {
        startFee = _startFee;
        endFee = _endFee;
        decayBlocks = _decayBlocks;
        taxBothDirections = _taxBothDirections;
    }

    /// @inheritdoc IDynamicFeeModule
    function getFee(PoolKey calldata key) external view returns (uint24 zeroForOneFee, uint24 oneForZeroFee) {
        uint48 swapStartBlock =
            IBondingCurveLaunchHook(address(key.hooks)).bondingCurveConfig(key.toId()).swapStartBlock;
        uint24 buyFee = _decayedFee(swapStartBlock);
        uint24 sellFee = taxBothDirections ? buyFee : endFee;
        // Native ETH (currency0) pairs against the token (currency1), so a token buy is zeroForOne.
        return (buyFee, sellFee);
    }

    /// @notice Interpolates the fee over the configured decay window.
    function _decayedFee(uint48 swapStartBlock) internal view returns (uint24) {
        uint256 currentBlock = _getBlockNumberish();
        if (currentBlock <= swapStartBlock) return startFee;
        uint256 elapsed = currentBlock - swapStartBlock;
        if (elapsed >= decayBlocks) return endFee;
        // elapsed is within the decay window.
        int256 delta =
            (int256(uint256(endFee)) - int256(uint256(startFee))) * int256(elapsed) / int256(uint256(decayBlocks));
        return uint24(uint256(int256(uint256(startFee)) + delta));
    }
}
