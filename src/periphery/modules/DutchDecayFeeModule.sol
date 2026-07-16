// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BlockNumberish} from "@uniswap/blocknumberish/src/BlockNumberish.sol";
import {IDynamicFeeModule} from "../../interfaces/IDynamicFeeModule.sol";
import {ILaunchHook, LaunchConfig} from "../../interfaces/ILaunchHook.sol";

/// @notice Module parameters, abi-encoded into LaunchConfig.moduleConfig
struct DutchDecayConfig {
    uint24 startFee; // fee in pips at the swap start block
    uint24 endFee; // fee in pips once decayBlocks have elapsed
    uint48 decayBlocks; // number of blocks over which the fee interpolates linearly from startFee to endFee
    bool taxBothDirections; // when false only token buys pay the decaying fee; token sells pay endFee
}

/// @title DutchDecayFeeModule
/// @notice Stateless fee module that linearly decays the LP fee from startFee to endFee over a block window
/// @dev Reads its window anchor, token ordering, and parameters from the launch hook at `key.hooks`. Shared
///      across pools; all per-pool state lives in the hook's LaunchConfig.
contract DutchDecayFeeModule is IDynamicFeeModule, BlockNumberish {
    /// @inheritdoc IDynamicFeeModule
    function getFee(PoolKey calldata key) external view returns (uint24 zeroForOneFee, uint24 oneForZeroFee) {
        LaunchConfig memory launch = ILaunchHook(address(key.hooks)).launchConfig(key.toId());
        DutchDecayConfig memory config = abi.decode(launch.moduleConfig, (DutchDecayConfig));

        uint24 buyFee = _decayedFee(config, launch.swapStartBlock);
        uint24 sellFee = config.taxBothDirections ? buyFee : config.endFee;
        // Buying the token consumes the pool's token-side liquidity: currency1 -> currency0 when the token
        // is currency0, currency0 -> currency1 otherwise.
        return launch.tokenIsCurrency0 ? (sellFee, buyFee) : (buyFee, sellFee);
    }

    /// @notice Linearly interpolates the fee from startFee to endFee over decayBlocks after swapStartBlock
    function _decayedFee(DutchDecayConfig memory config, uint48 swapStartBlock) internal view returns (uint24) {
        uint256 currentBlock = _getBlockNumberish();
        if (currentBlock <= swapStartBlock) return config.startFee;

        uint256 elapsed = currentBlock - swapStartBlock;
        if (elapsed >= config.decayBlocks) return config.endFee;

        // elapsed < decayBlocks, so the interpolation stays within [min(start, end), max(start, end)]
        int256 delta = (int256(uint256(config.endFee)) - int256(uint256(config.startFee))) * int256(elapsed)
            / int256(uint256(config.decayBlocks));
        return uint24(uint256(int256(uint256(config.startFee)) + delta));
    }
}
