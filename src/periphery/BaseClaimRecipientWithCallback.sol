// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IClaimExecutor} from "../interfaces/IClaimExecutor.sol";
import {BaseClaimRecipient} from "./BaseClaimRecipient.sol";

/// @title BaseClaimRecipientWithCallback
/// @notice Base for recipients whose `claim` calls back into the caller, bracketed by
///         `_beforeExecutorCallback`/`_afterExecutorCallback` hooks.
/// @dev The caller of `claim` MUST implement `IClaimExecutor`.
abstract contract BaseClaimRecipientWithCallback is BaseClaimRecipient {
    constructor(IPositionManager _positionManager) BaseClaimRecipient(_positionManager) {}

    /// @inheritdoc BaseClaimRecipient
    /// @dev Runs `_beforeExecutorCallback`, the executor callback, then `_afterExecutorCallback`.
    function _afterClaim(PoolKey memory poolKey, uint256 tokenId, uint256 toSend0, uint256 toSend1) internal override {
        uint256 context = _beforeExecutorCallback(poolKey, tokenId);
        IClaimExecutor(msg.sender).onClaimed(poolKey, tokenId, toSend0, toSend1);
        _afterExecutorCallback(poolKey, tokenId, context);
    }

    /// @notice Called before the executor callback
    /// @param poolKey The claimed position's pool key
    /// @param tokenId The claimed position's token ID
    /// @return context An opaque value passed through to `_afterExecutorCallback`
    function _beforeExecutorCallback(PoolKey memory poolKey, uint256 tokenId)
        internal
        virtual
        returns (uint256 context)
    {}

    /// @notice Called after the executor callback
    /// @param poolKey The claimed position's pool key
    /// @param tokenId The claimed position's token ID
    /// @param context The value returned by `_beforeExecutorCallback`
    function _afterExecutorCallback(PoolKey memory poolKey, uint256 tokenId, uint256 context) internal virtual {}
}
