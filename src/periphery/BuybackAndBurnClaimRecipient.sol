// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {BaseClaimRecipientWithCallback} from "./BaseClaimRecipientWithCallback.sol";

/// @title BuybackAndBurnClaimRecipient
/// @notice Singleton buyback-and-burn recipient for native-ETH-paired LP positions
/// @dev Every position must pair native ETH as currency0 with a standard 18-decimal ERC20 as currency1
/// @dev Callers of `claim` must approve this contract for at least `minCurrency1BurnAmount` of the
///      position's currency1, which is pulled from the caller and sent to the burn address
contract BuybackAndBurnClaimRecipient is BaseClaimRecipientWithCallback {
    /// @notice The address to send tokens to be burned
    address internal constant BURN_ADDRESS = address(0xdead);

    /// @notice The currency1 amount pulled from the caller and burned on every claim
    uint256 public immutable minCurrency1BurnAmount;

    /// @notice Thrown when the position's currency is not native ETH
    error InvalidCurrency(Currency received, Currency expected);
    /// @notice Thrown when the minimum currency1 burn amount is 0
    error ZeroMinCurrency1BurnAmount();

    /// @notice Emitted when caller-provided tokens are sent to the burn address
    event TokensBurned(uint256 indexed tokenId, Currency indexed token, uint256 amount);

    constructor(IPositionManager _positionManager, uint256 _minCurrency1BurnAmount)
        BaseClaimRecipientWithCallback(_positionManager)
    {
        if (_minCurrency1BurnAmount == 0) revert ZeroMinCurrency1BurnAmount();
        minCurrency1BurnAmount = _minCurrency1BurnAmount;
    }

    /// @inheritdoc BaseClaimRecipientWithCallback
    /// @dev Requires currency0 to be native ETH
    function _beforeExecutorCallback(PoolKey memory poolKey, uint256) internal pure override returns (uint256) {
        if (!poolKey.currency0.isAddressZero()) {
            revert InvalidCurrency(poolKey.currency0, CurrencyLibrary.ADDRESS_ZERO);
        }
        return 0;
    }

    /// @inheritdoc BaseClaimRecipientWithCallback
    /// @dev Burns `minCurrency1BurnAmount` of `poolKey.currency1` tokens
    function _afterExecutorCallback(PoolKey memory poolKey, uint256 tokenId, uint256) internal override {
        SafeTransferLib.safeTransferFrom(
            Currency.unwrap(poolKey.currency1), msg.sender, BURN_ADDRESS, minCurrency1BurnAmount
        );
        emit TokensBurned(tokenId, poolKey.currency1, minCurrency1BurnAmount);
    }
}
