// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {BaseBuybackAndBurnPositionRecipient} from "./BaseBuybackAndBurnPositionRecipient.sol";

/// @title CanonicalBuybackAndBurnPositionRecipient
/// @notice Buyback-and-burn recipient shared by canonically launched token/ETH positions
/// @dev Assumes every held position pairs native ETH as currency0 with a standard 18-decimal ERC20 as currency1
/// @dev Note that the same timelock and burn threshold is applied to every position held in this contract
contract CanonicalBuybackAndBurnPositionRecipient is BaseBuybackAndBurnPositionRecipient {
    /// @notice The currency paid to callers who collect fees
    Currency public constant currency = Currency.wrap(address(0));

    /// @notice Thrown when the position's currency is not native ETH
    error InvalidCurrency(Currency received, Currency expected);
    /// @notice Thrown when trying to rescue a conforming ETH-paired position
    error PositionConforming(uint256 tokenId);

    /// @notice Emitted when caller-provided tokens are sent to the burn address
    event TokensBurned(uint256 indexed tokenId, Currency indexed token, uint256 amount);

    /// @notice Emitted when position fees are collected
    event FeesCollected(
        uint256 indexed tokenId, address indexed caller, Currency indexed token, uint256 currencyAmount
    );

    /// @notice Emitted when a non-conforming position is rescued to the operator
    event NonConformingPositionRescued(uint256 indexed tokenId, Currency currency0);

    constructor(
        IPositionManager _positionManager,
        address _operator,
        uint256 _timelockBlockNumber,
        uint256 _minTokenBurnAmount
    ) BaseBuybackAndBurnPositionRecipient(_positionManager, _operator, _timelockBlockNumber, _minTokenBurnAmount) {}

    /// @notice Collects fees from a canonical token/ETH position and burns its token fees
    /// @param _tokenId The token ID of the position
    /// @param _minCurrencyAmount The minimum ETH fees the caller will accept
    function collectFees(uint256 _tokenId, uint256 _minCurrencyAmount) external nonReentrant {
        PoolKey memory poolKey = _getPoolKey(_tokenId);
        if (!(poolKey.currency0 == currency)) revert InvalidCurrency(poolKey.currency0, currency);

        Currency token = poolKey.currency1;
        _burnCallerTokens(token);
        emit TokensBurned(_tokenId, token, minTokenBurnAmount);

        uint256 currencyReceived = _collectAndPayFees(_tokenId, _minCurrencyAmount, token, currency);

        emit FeesCollected(_tokenId, msg.sender, token, currencyReceived);
    }

    /// @notice Transfers a position that does not pair native ETH as currency0 to the operator
    /// @param _tokenId The token ID of the invalid position
    function withdrawInvalidPosition(uint256 _tokenId) external {
        PoolKey memory poolKey = _getPoolKey(_tokenId);
        if (poolKey.currency0 == currency) revert PositionConforming(_tokenId);

        IERC721(address(positionManager)).transferFrom(address(this), operator, _tokenId);

        emit NonConformingPositionRescued(_tokenId, poolKey.currency0);
    }
}
