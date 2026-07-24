// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {IClaimExecutor} from "../interfaces/IClaimExecutor.sol";
import {IClaimablePositionRecipient} from "../interfaces/IClaimablePositionRecipient.sol";

/// @title BasePositionRecipient
/// @notice Shared amount attribution and executor claim mechanics for LP position recipients
abstract contract BasePositionRecipient is IClaimablePositionRecipient, ReentrancyGuardTransient {
    using SafeCast for uint256;

    /// @notice The position manager used to resolve positions and their pool keys
    IPositionManager public immutable positionManager;

    constructor(IPositionManager _positionManager) {
        positionManager = _positionManager;
    }

    struct Amounts {
        uint128 currency0Amount;
        uint128 currency1Amount;
    }
    mapping(uint256 tokenId => Amounts amounts) public override amounts;
    mapping(Currency currency => uint256 amount) public totalAmounts;

    /// @notice Returns the pool key for an existing position
    function _getPoolKey(uint256 _tokenId) internal view returns (PoolKey memory poolKey) {
        (poolKey,) = positionManager.getPoolAndPositionInfo(_tokenId);
        if (poolKey.tickSpacing == 0) revert InvalidPosition(_tokenId);
    }

    /// @inheritdoc IClaimablePositionRecipient
    function onAmountsReceived(uint256 _tokenId, uint256 _currency0Amount, uint256 _currency1Amount) external {
        PoolKey memory poolKey = _getPoolKey(_tokenId);

        Amounts memory positionAmounts = amounts[_tokenId];
        if (_currency0Amount != 0) {
            _attribute(poolKey.currency0, _currency0Amount);
            positionAmounts.currency0Amount = (positionAmounts.currency0Amount + _currency0Amount).toUint128();
        }
        if (_currency1Amount != 0) {
            _attribute(poolKey.currency1, _currency1Amount);
            positionAmounts.currency1Amount = (positionAmounts.currency1Amount + _currency1Amount).toUint128();
        }
        amounts[_tokenId] = positionAmounts;
    }

    /// @inheritdoc IClaimablePositionRecipient
    function claim(uint256 _tokenId, uint256 _minCurrency0Amount, uint256 _minCurrency1Amount) external nonReentrant {
        PoolKey memory poolKey = _getPoolKey(_tokenId);

        Currency currency0 = poolKey.currency0;
        Currency currency1 = poolKey.currency1;
        uint256 currency0Amount;
        uint256 currency1Amount;
        {
            Amounts memory positionAmounts = amounts[_tokenId];
            currency0Amount = positionAmounts.currency0Amount;
            currency1Amount = positionAmounts.currency1Amount;
        }

        if (currency0Amount < _minCurrency0Amount) {
            revert InsufficientAmountReceived(currency0, currency0Amount, _minCurrency0Amount);
        }
        if (currency1Amount < _minCurrency1Amount) {
            revert InsufficientAmountReceived(currency1, currency1Amount, _minCurrency1Amount);
        }

        (address recipient0, uint256 toSend0, address recipient1, uint256 toSend1) =
            _beforeTransfer(_tokenId, currency0, currency1, currency0Amount, currency1Amount);
        if (recipient0 == address(0)) revert InvalidTransferRecipient(currency0);
        if (recipient1 == address(0)) revert InvalidTransferRecipient(currency1);
        if (toSend0 > currency0Amount) revert InsufficientAmountReceived(currency0, currency0Amount, toSend0);
        if (toSend1 > currency1Amount) revert InsufficientAmountReceived(currency1, currency1Amount, toSend1);

        _payout(_tokenId, currency0, recipient0, toSend0, true);
        _payout(_tokenId, currency1, recipient1, toSend1, false);

        uint256 context = _beforeCallback(poolKey, _tokenId);

        // Callers without code skip the executor callback; the before/after hooks always run.
        if (msg.sender.code.length != 0) {
            IClaimExecutor(msg.sender).onClaimed(poolKey, _tokenId, toSend0, toSend1);
        }

        _afterCallback(poolKey, _tokenId, context);

        emit Claimed(_tokenId, toSend0, toSend1, poolKey);
    }

    /// @notice Decrements attribution before transferring, so code running during a payout cannot
    ///         attribute the in-flight funds.
    function _payout(uint256 _tokenId, Currency _currency, address _recipient, uint256 _toSend, bool _isCurrency0)
        private
    {
        if (_toSend == 0) return;
        // casts are safe as _toSend is bounded by the attributed uint128 amount
        if (_isCurrency0) amounts[_tokenId].currency0Amount -= uint128(_toSend);
        else amounts[_tokenId].currency1Amount -= uint128(_toSend);
        totalAmounts[_currency] -= _toSend;
        _currency.transfer(_recipient, _toSend);
    }

    /// @notice Requires `_amount` to be backed by balance beyond the amounts already attributed.
    function _attribute(Currency _currency, uint256 _amount) private {
        uint256 balance = _currency.balanceOfSelf();
        uint256 expectedTotalAmount = totalAmounts[_currency] + _amount;
        if (balance < expectedTotalAmount) revert InsufficientAmountReceived(_currency, balance, expectedTotalAmount);
        totalAmounts[_currency] = expectedTotalAmount;
    }

    /// @notice Transfer policy consulted once per claim, before any payout. Defaults to paying the
    ///         full available amounts to the caller.
    /// @dev Zero recipients revert — burning must be an explicit 0xdead. Amounts below the available
    ///      balance leave the remainder attributed and claimable later.
    function _beforeTransfer(uint256, Currency, Currency, uint256 _available0, uint256 _available1)
        internal
        virtual
        returns (address recipient0, uint256 toSend0, address recipient1, uint256 toSend1)
    {
        return (msg.sender, _available0, msg.sender, _available1);
    }

    /// @notice Called before the callback is executed
    /// @return context An opaque value passed through to `_afterCallback`
    function _beforeCallback(PoolKey memory _poolKey, uint256 _tokenId) internal virtual returns (uint256 context) {}

    /// @notice Called after the callback is executed
    /// @param _context The value returned by `_beforeCallback`
    function _afterCallback(PoolKey memory _poolKey, uint256 _tokenId, uint256 _context) internal virtual {}

    /// @notice Receive ETH
    receive() external payable {}
}
