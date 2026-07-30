// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BaseClaimRecipientWithCallback} from "./BaseClaimRecipientWithCallback.sol";

/// @title CompoundingClaimRecipient
/// @notice Claims attributed amounts through an executor and compounds assets deposited into PositionManager
/// @dev Compounds only into the claimed position's existing range. Positions MUST use boundary ticks
///      that are costly to saturate; a boundary tick at `maxLiquidityPerTick` blocks every claim.
contract CompoundingClaimRecipient is BaseClaimRecipientWithCallback {
    /// @notice The minimum liquidity increase required per claim
    uint128 public immutable minLiquidityIncrease;

    /// @notice Thrown when the minimum liquidity increase is zero
    error ZeroMinLiquidityIncrease();

    /// @notice Thrown when the position's liquidity does not increase by at least `minLiquidityIncrease`
    /// @param actual The position's liquidity after the callback
    /// @param required The liquidity the position must reach
    error InsufficientLiquidityIncrease(uint256 actual, uint256 required);

    constructor(IPositionManager _positionManager, uint128 _minLiquidityIncrease)
        BaseClaimRecipientWithCallback(_positionManager)
    {
        if (_minLiquidityIncrease == 0) revert ZeroMinLiquidityIncrease();
        minLiquidityIncrease = _minLiquidityIncrease;
    }

    /// @inheritdoc BaseClaimRecipientWithCallback
    /// @dev Snapshots the position's liquidity before the executor callback
    function _beforeExecutorCallback(PoolKey memory, uint256 tokenId) internal view override returns (uint256) {
        return positionManager.getPositionLiquidity(tokenId);
    }

    /// @inheritdoc BaseClaimRecipientWithCallback
    /// @param liquidityBefore The position's liquidity snapshotted by `_beforeExecutorCallback`
    function _afterExecutorCallback(PoolKey memory, uint256 tokenId, uint256 liquidityBefore) internal view override {
        uint128 actualLiquidity = positionManager.getPositionLiquidity(tokenId);
        uint256 requiredLiquidity = liquidityBefore + minLiquidityIncrease;
        if (actualLiquidity < requiredLiquidity) {
            revert InsufficientLiquidityIncrease(actualLiquidity, requiredLiquidity);
        }
    }
}
