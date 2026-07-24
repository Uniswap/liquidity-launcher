// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {BasePositionRecipientWithCallback} from "./BasePositionRecipientWithCallback.sol";

/// @title BuybackAndBurnPositionRecipient
/// @notice Singleton buyback-and-burn recipient for native-ETH-paired LP positions
/// @dev Assumes every position pairs native ETH as currency0 with a standard 18-decimal ERC20 as currency1
/// @dev This contract is not intended to hold positions; it only receives amount notifications
/// @dev The same burn threshold is applied to every position
/// @dev Callers of `claim` must approve this contract for at least `minCurrency1BurnAmount` of the
///      position's currency1, which is pulled from the caller and sent to the burn address
contract BuybackAndBurnPositionRecipient is BasePositionRecipientWithCallback {
    /// @notice The currency paid to callers who claim
    Currency public constant currency = CurrencyLibrary.ADDRESS_ZERO;

    /// @notice The address to send tokens to be burned
    address internal constant BURN_ADDRESS = address(0xdead);

    /// @notice Thrown when the position's currency is not native ETH
    error InvalidCurrency(Currency received, Currency expected);
    /// @notice Thrown when the minimum currency1 burn amount is 0
    error InvalidMinCurrency1BurnAmount();

    /// @notice Emitted when caller-provided tokens are sent to the burn address
    event TokensBurned(uint256 indexed tokenId, Currency indexed token, uint256 amount);

    uint256 public immutable minCurrency1BurnAmount;

    constructor(IPositionManager _positionManager, uint256 _minCurrency1BurnAmount)
        BasePositionRecipientWithCallback(_positionManager)
    {
        if (_minCurrency1BurnAmount == 0) revert InvalidMinCurrency1BurnAmount();
        minCurrency1BurnAmount = _minCurrency1BurnAmount;
    }

    /// @inheritdoc BasePositionRecipientWithCallback
    /// @dev Requires native ETH as currency0, which also guarantees currency1 is the ERC20 burn target
    function _beforeCallback(PoolKey memory _poolKey, uint256) internal pure override returns (uint256) {
        if (!_poolKey.currency0.isAddressZero()) revert InvalidCurrency(_poolKey.currency0, currency);
        return 0;
    }

    /// @inheritdoc BasePositionRecipientWithCallback
    /// @dev Burns `minCurrency1BurnAmount` of `_poolKey.currency1` tokens
    function _afterCallback(PoolKey memory _poolKey, uint256 _tokenId, uint256) internal override {
        SafeTransferLib.safeTransferFrom(
            Currency.unwrap(_poolKey.currency1), msg.sender, BURN_ADDRESS, minCurrency1BurnAmount
        );
        emit TokensBurned(_tokenId, _poolKey.currency1, minCurrency1BurnAmount);
    }
}
