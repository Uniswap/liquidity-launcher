// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IClaimableRecipient} from "../interfaces/IClaimableRecipient.sol";
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
    /// @param required The liquidity the position must reach
    /// @param actual The position's liquidity after the callback
    error NotEnoughLiquidityAdded(uint256 required, uint256 actual);

    /// @notice The minimum liquidity increase required to be compounded
    uint128 public immutable minLiquidityIncrease;

    constructor(IPositionManager _positionManager, uint128 _minLiquidityIncrease)
        BaseClaimRecipientWithCallback(_positionManager)
    {
        if (_minLiquidityIncrease == 0) revert MinLiquidityIncreaseIsZero();
        minLiquidityIncrease = _minLiquidityIncrease;
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
        uint256 requiredLiquidityAmount = _liquidityBefore + minLiquidityIncrease;
        if (actualLiquidityAmount < requiredLiquidityAmount) {
            revert NotEnoughLiquidityAdded(requiredLiquidityAmount, actualLiquidityAmount);
        }
    }

    /// @notice Pulls a beneficiary vault's attributed fee share into this recipient's accounting.
    /// @dev For split fee setups where this recipient owns the beneficiary NFT and receives the
    ///      compounding callback. The vault enforces NFT ownership on `claim`; pulled amounts are
    ///      re-attributed here so a subsequent `claim` can compound the direct splitter share and
    ///      the vault share in one executor callback.
    /// @param source The beneficiary vault (or other external recipient) to pull from
    /// @param tokenId The position token ID
    /// @param minCurrency0Amount Minimum currency0 the external recipient must pay out
    /// @param minCurrency1Amount Minimum currency1 the external recipient must pay out
    function claimFrom(
        IClaimableRecipient source,
        uint256 tokenId,
        uint256 minCurrency0Amount,
        uint256 minCurrency1Amount
    ) external nonReentrant {
        (uint256 currency0Amount, uint256 currency1Amount) = source.amounts(tokenId);
        // Min amounts are validated by the external recipient
        source.claim(tokenId, minCurrency0Amount, minCurrency1Amount);
        onAmountsReceived(tokenId, currency0Amount, currency1Amount);
    }
}
