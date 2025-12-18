// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TimelockedPositionRecipient} from "./TimelockedPositionRecipient.sol";
import {Multicall} from "../Multicall.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @title PositionFeesForwarder
/// @notice Utility contract for forwarding the fees from v4 LP positions to a recipient
/// @custom:security-contact security@uniswap.org
contract PositionFeesForwarder is TimelockedPositionRecipient, Multicall {
    using CurrencyLibrary for Currency;

    /// @notice Thrown when this contract is not the owner of the position
    error NotPositionOwner();

    /// @notice Emitted when fees are forwarded
    /// @param recipient The recipient of the fees
    /// @param token0Fees The amount of token0 fees forwarded
    /// @param token1Fees The amount of token1 fees forwarded
    event FeesForwarded(address indexed recipient, uint256 token0Fees, uint256 token1Fees);

    /// @notice The recipient of collected fees
    address public immutable recipient;

    constructor(IPositionManager _positionManager, address _operator, uint256 _timelockBlockNumber, address _recipient)
        TimelockedPositionRecipient(_positionManager, _operator, _timelockBlockNumber)
    {
        recipient = _recipient;
    }

    /// @notice Collect any fees from the position and forward them to the set recipient
    /// @param tokenId the token ID of the position
    /// @param token0 the address of token0 on the pool
    /// @param token1 the address of token1 on the pool
    function collectFees(uint256 tokenId, address token0, address token1) external nonReentrant {
        // Check if the caller is the owner of the position
        if (IERC721(address(positionManager)).ownerOf(tokenId) != address(this)) revert NotPositionOwner();

        // Collect the fees from the position
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, 0, 0, 0, bytes("")); // decreaseLiquidityParams
        params[1] = abi.encode(token0, token1, address(this), 0); // takeParams

        // Set deadline to the current block
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);

        // Transfer all fees to the recipient
        uint256 token0Fees = Currency.wrap(token0).balanceOfSelf();
        uint256 token1Fees = Currency.wrap(token1).balanceOfSelf();
        Currency.wrap(token0).transfer(recipient, token0Fees);
        Currency.wrap(token1).transfer(recipient, token1Fees);

        emit FeesForwarded(recipient, token0Fees, token1Fees);
    }
}
