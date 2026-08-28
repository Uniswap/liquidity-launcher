// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {BaseClaimRecipientWithCallback} from "./BaseClaimRecipientWithCallback.sol";

/// @title BuybackAndBurnClaimRecipient
/// @notice Singleton buyback-and-burn recipient for LP positions
/// @dev The immutable `burnCurrency0` selects the burn currency for every position: currency0 when true,
///      currency1 when false. The burn currency must be an ERC20, so claims on positions whose burn
///      currency is native ETH revert
/// @dev This contract is not intended to hold positions; it only receives amount notifications
/// @dev The same burn threshold is applied to every position
/// @dev Callers of `claim` must approve this contract for at least `minBurnAmount` of the
///      position's burn currency, which is pulled from the caller and sent to the burn address
contract BuybackAndBurnClaimRecipient is BaseClaimRecipientWithCallback {
    /// @notice The address to send tokens to be burned
    address internal constant BURN_ADDRESS = address(0xdead);

    /// @notice Thrown when the position's burn currency is native ETH
    error InvalidBurnCurrency();
    /// @notice Thrown when the minimum burn amount is 0
    error InvalidMinBurnAmount();

    /// @notice Emitted when caller-provided tokens are sent to the burn address
    event TokensBurned(uint256 indexed tokenId, Currency indexed token, uint256 amount);

    /// @notice True to burn the position's currency0, false to burn currency1
    bool public immutable burnCurrency0;

    /// @notice The minimum amount of the burn currency pulled from the caller on each claim
    uint256 public immutable minBurnAmount;

    constructor(IPositionManager _positionManager, bool _burnCurrency0, uint256 _minBurnAmount)
        BaseClaimRecipientWithCallback(_positionManager)
    {
        if (_minBurnAmount == 0) revert InvalidMinBurnAmount();
        burnCurrency0 = _burnCurrency0;
        minBurnAmount = _minBurnAmount;
    }

    /// @inheritdoc BaseClaimRecipientWithCallback
    /// @dev Requires the burn currency to be an ERC20, not native ETH
    function _beforeExecutorCallback(PoolKey memory _poolKey, uint256) internal view override returns (uint256) {
        if (_burnCurrency(_poolKey).isAddressZero()) revert InvalidBurnCurrency();
        return 0;
    }

    /// @inheritdoc BaseClaimRecipientWithCallback
    /// @dev Burns `minBurnAmount` of the position's burn currency
    function _afterExecutorCallback(PoolKey memory _poolKey, uint256 _tokenId, uint256) internal override {
        Currency burnCurrency = _burnCurrency(_poolKey);
        SafeTransferLib.safeTransferFrom(Currency.unwrap(burnCurrency), msg.sender, BURN_ADDRESS, minBurnAmount);
        emit TokensBurned(_tokenId, burnCurrency, minBurnAmount);
    }

    /// @notice Returns the pool currency this recipient burns, selected by `burnCurrency0`
    function _burnCurrency(PoolKey memory _poolKey) internal view returns (Currency) {
        return burnCurrency0 ? _poolKey.currency0 : _poolKey.currency1;
    }
}
