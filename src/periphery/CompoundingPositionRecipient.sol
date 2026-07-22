// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BaseLPFeesPositionRecipient} from "./BaseLPFeesPositionRecipient.sol";

/// @title CompoundingPositionRecipient
/// @notice Collects LP fees through an executor and compounds assets deposited into PositionManager
contract CompoundingPositionRecipient is BaseLPFeesPositionRecipient {
    /// @notice Thrown when the minimum liquidity increase is zero
    error MinLiquidityIncreaseIsZero();

    /// @notice Thrown when the liquidity of the position did not increase by at least the required liquidity amount
    error NotEnoughLiquidityAdded(uint256 required, uint256 actual);

    /// @notice The minimum liquidity increase required to be compounded
    uint128 public immutable MIN_LIQUIDITY_INCREASE;

    constructor(
        IPositionManager _positionManager,
        address _operator,
        uint256 _timelockBlockNumber,
        uint128 _minLiquidityIncrease
    ) BaseLPFeesPositionRecipient(_positionManager, _operator, _timelockBlockNumber) {
        if (_minLiquidityIncrease == 0) revert MinLiquidityIncreaseIsZero();
        MIN_LIQUIDITY_INCREASE = _minLiquidityIncrease;
    }

    /// @inheritdoc BaseLPFeesPositionRecipient
    /// @dev Snapshots the position's liquidity before the executor callback
    function _beforeCallback(PoolKey memory, uint256 _tokenId) internal view override returns (uint256) {
        return positionManager.getPositionLiquidity(_tokenId);
    }

    /// @inheritdoc BaseLPFeesPositionRecipient
    /// @param _liquidityBefore The position's liquidity snapshotted by `_beforeCallback`
    function _afterCallback(PoolKey memory, uint256 _tokenId, uint256 _liquidityBefore) internal view override {
        uint128 actualLiquidityAmount = positionManager.getPositionLiquidity(_tokenId);
        uint256 requiredLiquidityAmount = _liquidityBefore + MIN_LIQUIDITY_INCREASE;
        if (actualLiquidityAmount < requiredLiquidityAmount) {
            revert NotEnoughLiquidityAdded(requiredLiquidityAmount, actualLiquidityAmount);
        }
    }
}
