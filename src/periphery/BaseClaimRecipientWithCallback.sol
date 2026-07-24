// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IClaimExecutor} from "../interfaces/IClaimExecutor.sol";
import {BaseClaimRecipient} from "./BaseClaimRecipient.sol";

/// @title BaseClaimRecipientWithCallback
/// @notice Base for recipients whose claim MUST call back into the caller so it can act on the funds it
///         was just paid, bracketed by `_beforeExecutorCallback`/`_afterExecutorCallback` hooks that let the recipient
///         verify the caller did what it was supposed to (compound the liquidity, fund the burn, etc.).
/// @dev The callback is not optional: the caller of `claim` MUST implement `IClaimExecutor`. Recipients
///      that don't need a callback must inherit `BaseClaimRecipient` directly instead.
abstract contract BaseClaimRecipientWithCallback is BaseClaimRecipient {
    constructor(IPositionManager _positionManager) BaseClaimRecipient(_positionManager) {}

    /// @inheritdoc BaseClaimRecipient
    /// @dev Runs `_beforeExecutorCallback`, the mandatory executor callback, then `_afterExecutorCallback`. The
    ///      before/after hooks bracket the callback so a subclass can snapshot state and enforce the
    ///      caller's obligation across it.
    function _afterClaim(PoolKey memory _poolKey, uint256 _tokenId, uint256 _toSend0, uint256 _toSend1)
        internal
        override
    {
        uint256 context = _beforeExecutorCallback(_poolKey, _tokenId);
        IClaimExecutor(msg.sender).onClaimed(_poolKey, _tokenId, _toSend0, _toSend1);
        _afterExecutorCallback(_poolKey, _tokenId, context);
    }

    /// @notice Called before the executor callback
    /// @return context An opaque value passed through to `_afterExecutorCallback`
    function _beforeExecutorCallback(PoolKey memory _poolKey, uint256 _tokenId) internal virtual returns (uint256 context) {}

    /// @notice Called after the executor callback
    /// @param _context The value returned by `_beforeExecutorCallback`
    function _afterExecutorCallback(PoolKey memory _poolKey, uint256 _tokenId, uint256 _context) internal virtual {}
}
