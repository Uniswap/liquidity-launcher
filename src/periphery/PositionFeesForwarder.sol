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

/// @title PositionFeesForwarder
/// @notice Utility contract for forwarding the fees from a v4 LP position to a recipient
contract PositionFeesForwarder is ReentrancyGuardTransient {
    using CurrencyLibrary for Currency;

    error PositionIsTimelocked();
    error NotPositionOwner();

    /// @notice Emitted when the operator is approved to transfer the position
    /// @param tokenId The token ID of the position
    /// @param operator The configured operator
    event OperatorApproved(uint256 indexed tokenId, address indexed operator);

    /// @notice Emitted when fees are forwarded
    /// @param recipient The recipient of the fees
    /// @param token0Fees The amount of token0 fees forwarded
    /// @param token1Fees The amount of token1 fees forwarded
    event FeesForwarded(address indexed recipient, uint256 token0Fees, uint256 token1Fees);

    /// @notice The position manager that will be used to create the position
    IPositionManager public immutable POSITION_MANAGER;
    /// @notice The operator that will be approved to transfer the position
    address public immutable OPERATOR;
    /// @notice The block number at which the operator will be approved to transfer the position
    uint256 public immutable TIMELOCK_BLOCK_NUMBER;
    /// @notice The recipient of collected fees
    address public immutable RECIPIENT;

    constructor(IPositionManager positionManager, address operator, uint256 timelockBlockNumber, address recipient) {
        POSITION_MANAGER = positionManager;
        OPERATOR = operator;
        TIMELOCK_BLOCK_NUMBER = timelockBlockNumber;
        RECIPIENT = recipient;
    }

    /// @notice Claim any fees from the position and burn the `tokens` portion
    /// @param tokenId The token ID of the position
    function collectFees(uint256 tokenId, address token0, address token1) external nonReentrant {
        if (IERC721(address(POSITION_MANAGER)).ownerOf(tokenId) != address(this)) revert NotPositionOwner();

        // Collect the fees from the position
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, 0, 0, 0, bytes("")); // decreaseLiquidityParams
        params[1] = abi.encode(token0, token1, address(this), 0); // takeParams

        // Set deadline to the current block
        POSITION_MANAGER.modifyLiquidities(abi.encode(actions, params), block.timestamp);

        // Transfer all fees to the recipient
        uint256 token0Fees = Currency.wrap(token0).balanceOfSelf();
        uint256 token1Fees = Currency.wrap(token1).balanceOfSelf();
        Currency.wrap(token0).transfer(RECIPIENT, token0Fees);
        Currency.wrap(token1).transfer(RECIPIENT, token1Fees);

        emit FeesForwarded(RECIPIENT, token0Fees, token1Fees);
    }

    /// @notice Approves the operator to transfer the position
    /// @dev Can be called by anyone after the timelock period has passed
    /// @param tokenId The token ID of the position
    function approveOperator(uint256 tokenId) external {
        if (block.number < TIMELOCK_BLOCK_NUMBER) revert PositionIsTimelocked();

        IERC721(address(POSITION_MANAGER)).approve(OPERATOR, tokenId);

        emit OperatorApproved(tokenId, OPERATOR);
    }

    receive() external payable {}
}
