// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
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
    function _afterCallback(PoolKey memory _poolKey, uint256 _tokenId, uint256 _liquidityBefore) internal override {
        bool hasNativeCurrency = _poolKey.currency0.isAddressZero();
        uint256 offset = hasNativeCurrency ? 1 : 0;
        bytes memory actions;
        bytes[] memory params = new bytes[](4 + offset);

        if (hasNativeCurrency) {
            actions = abi.encodePacked(
                uint8(Actions.UNWRAP),
                uint8(Actions.SETTLE),
                uint8(Actions.SETTLE),
                uint8(Actions.INCREASE_LIQUIDITY_FROM_DELTAS),
                uint8(Actions.TAKE_PAIR)
            );
            params[0] = abi.encode(ActionConstants.CONTRACT_BALANCE);
        } else {
            actions = abi.encodePacked(
                uint8(Actions.SETTLE),
                uint8(Actions.SETTLE),
                uint8(Actions.INCREASE_LIQUIDITY_FROM_DELTAS),
                uint8(Actions.TAKE_PAIR)
            );
        }

        params[offset] = abi.encode(_poolKey.currency0, ActionConstants.CONTRACT_BALANCE, false);
        params[offset + 1] = abi.encode(_poolKey.currency1, ActionConstants.CONTRACT_BALANCE, false);
        params[offset + 2] = abi.encode(_tokenId, type(uint128).max, type(uint128).max, bytes(""));
        params[offset + 3] = abi.encode(_poolKey.currency0, _poolKey.currency1, msg.sender);

        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);

        // Require that the liquidity of the position increased by at least the required liquidity amount
        uint128 actualLiquidityAmount = positionManager.getPositionLiquidity(_tokenId);
        uint256 requiredLiquidityAmount = _liquidityBefore + MIN_LIQUIDITY_INCREASE;
        if (actualLiquidityAmount < requiredLiquidityAmount) {
            revert NotEnoughLiquidityAdded(requiredLiquidityAmount, actualLiquidityAmount);
        }
    }
}
