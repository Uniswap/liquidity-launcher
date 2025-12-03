// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";

interface IERC721 {
    function ownerOf(uint256 tokenId) external view returns (address);
    function approve(address to, uint256 tokenId) external;
}

/// @title BuybackAndBurnPositionRecipient
/// @notice Utility contract for holding a v4 LP position and burning the fees accrued from the position
/// @dev Fees can be collected once the value of the currency portion exceeds the configured minimum burn amount
contract BuybackAndBurnPositionRecipient is ReentrancyGuardTransient {
    using CurrencyLibrary for Currency;

    error InvalidToken();
    error TokenAndCurrencyCannotBeTheSame();
    error PositionIsTimelocked();
    error NotPositionOwner();

    /// @notice Emitted when tokens are burned
    /// @param amount The amount of tokens burned
    event TokensBurned(uint256 amount);

    /// @notice Emitted when the operator is approved to transfer the position
    /// @param tokenId The token ID of the position
    /// @param operator The configured operator
    event OperatorApproved(uint256 indexed tokenId, address indexed operator);

    /// @notice Emitted when fees are collected
    /// @param recipient The recipient of the currency fees
    /// @param amount The amount of currency fees collected
    event CurrencyFeesCollected(address indexed recipient, uint256 amount);

    /// @notice The block number at which the operator will be approved to transfer the position
    uint256 public immutable TIMELOCK_BLOCK_NUMBER;
    /// @notice The minimum amount of `token` which must be burned each time fees are collected
    uint256 public immutable MIN_TOKEN_BURN_AMOUNT;
    /// @notice The token that will be burned
    address public immutable TOKEN;
    /// @notice The currency that will be used to collect fees
    address public immutable CURRENCY;
    /// @notice The operator that will be approved to transfer the position
    address public immutable OPERATOR;
    /// @notice The position manager that will be used to create the position
    IPositionManager public immutable POSITION_MANAGER;

    constructor(
        address token,
        address currency,
        address operator,
        IPositionManager positionManager,
        uint256 timelockBlockNumber,
        uint256 minTokenBurnAmount
    ) {
        if (token == address(0)) revert InvalidToken();
        if (token == currency) revert TokenAndCurrencyCannotBeTheSame();
        TOKEN = token;
        CURRENCY = currency;
        OPERATOR = operator;
        POSITION_MANAGER = positionManager;
        TIMELOCK_BLOCK_NUMBER = timelockBlockNumber;
        MIN_TOKEN_BURN_AMOUNT = minTokenBurnAmount;
    }

    /// @notice Claim any fees from the position and burn the `tokens` portion
    /// @param tokenId The token ID of the position
    function collectFees(uint256 tokenId) external nonReentrant {
        if (IERC721(address(POSITION_MANAGER)).ownerOf(tokenId) != address(this)) revert NotPositionOwner();

        // Require the caller to burn at least the minimum amount of `token`
        _burnTokensFrom(msg.sender, MIN_TOKEN_BURN_AMOUNT);

        // Collect the fees from the position
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, 0, 0, 0, bytes("")); // decreaseLiquidityParams
        params[1] = abi.encode(TOKEN, CURRENCY, address(this), 0); // takeParams

        uint256 tokenBalanceBefore = Currency.wrap(TOKEN).balanceOfSelf();
        uint256 currencyBalanceBefore = Currency.wrap(CURRENCY).balanceOfSelf();
        // Set deadline to the current block
        POSITION_MANAGER.modifyLiquidities(abi.encode(actions, params), block.timestamp);

        uint256 accruedTokenFees = Currency.wrap(TOKEN).balanceOfSelf() - tokenBalanceBefore;
        uint256 accruedCurrencyFees = Currency.wrap(CURRENCY).balanceOfSelf() - currencyBalanceBefore;

        // Burn the tokens from the collected fees
        _burnTokensFrom(address(this), accruedTokenFees);
        // Transfer the currency fees to the caller
        Currency.wrap(CURRENCY).transfer(msg.sender, accruedCurrencyFees);

        emit CurrencyFeesCollected(msg.sender, accruedCurrencyFees);
    }

    /// @notice Approves the operator to transfer the position
    /// @dev Can be called by anyone after the timelock period has passed
    /// @param tokenId The token ID of the position
    function approveOperator(uint256 tokenId) external {
        if (block.number < TIMELOCK_BLOCK_NUMBER) revert PositionIsTimelocked();

        IERC721(address(POSITION_MANAGER)).approve(OPERATOR, tokenId);

        emit OperatorApproved(tokenId, OPERATOR);
    }

    /// @notice Burns the tokens by transferring them to the burn address
    /// @dev Ensure that the `token` ERC20 contract allows transfers to address(0xdead)
    /// @param amount The amount of tokens to burn
    function _burnTokensFrom(address from, uint256 amount) internal {
        if (amount > 0) {
            if (from == address(this)) {
                Currency.wrap(TOKEN).transfer(address(0xdead), amount);
            } else {
                SafeTransferLib.safeTransferFrom(TOKEN, from, address(0xdead), amount);
            }
        }
        emit TokensBurned(amount);
    }

    receive() external payable {}
}
