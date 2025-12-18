// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TimelockedPositionRecipient} from "./TimelockedPositionRecipient.sol";
import {Multicall} from "../Multicall.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @title PositionFeesForwarder
/// @notice Utility contract for holding v4 LP positions and forwarding fees to a recipient
/// @custom:security-contact security@uniswap.org
contract PositionFeesForwarder is TimelockedPositionRecipient, Multicall {
    using CurrencyLibrary for Currency;

    /// @notice Thrown when this contract is not the owner of the position
    error NotPositionOwner();

    /// @notice Emitted when fees are forwarded
    /// @param feeRecipient The recipient of the fees
    /// @param token0Fees The amount of token0 fees forwarded
    /// @param token1Fees The amount of token1 fees forwarded
    event FeesForwarded(address indexed feeRecipient, uint256 token0Fees, uint256 token1Fees);

    /// @notice The recipient of collected fees. If set to a contract, it must be able to receive ETH.
    address public immutable feeRecipient;

    constructor(
        IPositionManager _positionManager,
        address _operator,
        uint256 _timelockBlockNumber,
        address _feeRecipient
    ) TimelockedPositionRecipient(_positionManager, _operator, _timelockBlockNumber) {
        feeRecipient = _feeRecipient;
    }

    /// @notice Collect any fees from the position and forward them to the set recipient
    /// @param _tokenId the token ID of the position
    /// @param _token0 the address of token0 on the pool
    /// @param _token1 the address of token1 on the pool
    function collectFees(uint256 _tokenId, address _token0, address _token1) external nonReentrant {
        // Check if this contract is the owner of the position
        if (IERC721(address(positionManager)).ownerOf(_tokenId) != address(this)) revert NotPositionOwner();

        // Collect the fees from the position
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        // Call DECREASE_LIQUIDITY with a liquidity of 0 to collect fees
        params[0] = abi.encode(_tokenId, 0, 0, 0, bytes(""));
        // Call TAKE_PAIR to close the open deltas
        params[1] = abi.encode(_token0, _token1, address(this));

        // Call modifyLiquidity with the actions and params, setting the deadline to the current block
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);

        // Transfer all collected fees to the fee recipient
        uint256 token0Fees = Currency.wrap(_token0).balanceOfSelf();
        uint256 token1Fees = Currency.wrap(_token1).balanceOfSelf();
        Currency.wrap(_token0).transfer(feeRecipient, token0Fees);
        Currency.wrap(_token1).transfer(feeRecipient, token1Fees);

        emit FeesForwarded(feeRecipient, token0Fees, token1Fees);
    }
}
