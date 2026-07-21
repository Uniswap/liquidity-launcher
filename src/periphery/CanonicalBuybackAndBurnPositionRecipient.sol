// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
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

    /// @notice Emitted when a non-conforming position is rescued to the operator
    event InvalidPositionWithdrawn(uint256 indexed tokenId, Currency currency0);

    /// @notice Thrown when the minimum currency1 burn amount is 0
    error InvalidMinCurrency1BurnAmount();

    uint256 public immutable minCurrency1BurnAmount;

    constructor(
        IPositionManager _positionManager,
        address _operator,
        uint256 _timelockBlockNumber,
        uint256 _minCurrency1BurnAmount
    ) BaseBuybackAndBurnPositionRecipient(_positionManager, _operator, _timelockBlockNumber) {
        if (_minCurrency1BurnAmount == 0) revert InvalidMinCurrency1BurnAmount();
        minCurrency1BurnAmount = _minCurrency1BurnAmount;
    }

    /// @inheritdoc BaseBuybackAndBurnPositionRecipient
    /// @dev Validates that the currency0 is native ETH
    function _beforeCallback(PoolKey memory _poolKey, uint256, uint256, uint256) internal pure override {
        if (!(_poolKey.currency0 == Currency.wrap(address(0)))) {
            revert InvalidCurrency(_poolKey.currency0, Currency.wrap(address(0)));
        }
    }

    /// @inheritdoc BaseBuybackAndBurnPositionRecipient
    /// @dev Burns `minCurrency1BurnAmount` of `_poolKey.currency1` tokens
    function _afterCallback(PoolKey memory _poolKey, uint256 _tokenId, uint256, uint256) internal override {
        SafeTransferLib.safeTransferFrom(
            Currency.unwrap(_poolKey.currency1), msg.sender, BURN_ADDRESS, minCurrency1BurnAmount
        );
        emit TokensBurned(_tokenId, _poolKey.currency1, minCurrency1BurnAmount);
    }

    /// @notice Transfers a position that does not pair native ETH as currency0 to the operator
    /// @param _tokenId The token ID of the invalid position
    function withdrawInvalidPosition(uint256 _tokenId) external {
        PoolKey memory poolKey = _getPoolKey(_tokenId);
        if (poolKey.currency0 == Currency.wrap(address(0))) revert PositionConforming(_tokenId);

        IERC721(address(positionManager)).transferFrom(address(this), operator, _tokenId);

        emit InvalidPositionWithdrawn(_tokenId, poolKey.currency0);
    }
}
