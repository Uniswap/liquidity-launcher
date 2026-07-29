// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BaseClaimRecipientWithCallback} from "./BaseClaimRecipientWithCallback.sol";

/// @title CompoundingClaimRecipient
/// @notice Claims attributed amounts through an executor and compounds assets deposited into PositionManager
/// @dev Compounds only into the claimed position's existing range. Once either of that range's boundary ticks
///      holds `maxLiquidityPerTick`, no increase is possible and every claim on the position reverts, so
///      positions assigned here MUST use boundary ticks that are costly to saturate.
contract CompoundingClaimRecipient is BaseClaimRecipientWithCallback {
    /// @notice Thrown when the minimum liquidity increase is zero
    error MinLiquidityIncreaseIsZero();

    /// @notice Thrown when the liquidity of the position did not increase by at least the required liquidity amount
    error NotEnoughLiquidityAdded(uint256 required, uint256 actual);

    /// @notice The minimum liquidity increase required to be compounded
    /// @dev Denominated in liquidity, not in the claimed amounts: any increase of at least this size satisfies
    ///      a claim, whoever funded it. `claim` is permissionless and pays the caller first, so what holds a
    ///      claim to compounding what it paid out is competition for that payout; this value only floors what
    ///      the position receives per claim when no one competes. Set it against the position's liquidity, not
    ///      against an expected fee amount.
    uint128 public immutable MIN_LIQUIDITY_INCREASE;

    constructor(IPositionManager _positionManager, uint128 _minLiquidityIncrease)
        BaseClaimRecipientWithCallback(_positionManager)
    {
        if (_minLiquidityIncrease == 0) revert MinLiquidityIncreaseIsZero();
        MIN_LIQUIDITY_INCREASE = _minLiquidityIncrease;
    }

    /// @inheritdoc BaseClaimRecipientWithCallback
    /// @dev Snapshots the position's liquidity before the executor callback
    function _beforeExecutorCallback(PoolKey memory, uint256 _tokenId) internal view override returns (uint256) {
        return positionManager.getPositionLiquidity(_tokenId);
    }

    /// @inheritdoc BaseClaimRecipientWithCallback
    /// @param _liquidityBefore The position's liquidity snapshotted by `_beforeExecutorCallback`
    function _afterExecutorCallback(PoolKey memory, uint256 _tokenId, uint256 _liquidityBefore) internal view override {
        uint128 actualLiquidityAmount = positionManager.getPositionLiquidity(_tokenId);
        uint256 requiredLiquidityAmount = _liquidityBefore + MIN_LIQUIDITY_INCREASE;
        if (actualLiquidityAmount < requiredLiquidityAmount) {
            revert NotEnoughLiquidityAdded(requiredLiquidityAmount, actualLiquidityAmount);
        }
    }
}
