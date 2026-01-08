// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TimelockedPositionRecipient} from "./TimelockedPositionRecipient.sol";
import {Multicall} from "../Multicall.sol";

/// @title PositionFeesForwarder
/// @notice Utility contract for holding v4 LP positions and forwarding fees to a recipient
/// @custom:security-contact security@uniswap.org
contract PositionFeesForwarder is TimelockedPositionRecipient, Multicall {
    /// @notice Emitted when fees are forwarded
    /// @param feeRecipient The recipient of the fees
    event FeesForwarded(address indexed feeRecipient);

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
    function collectFees(uint256 _tokenId) external nonReentrant requireOwned(_tokenId) {
        (PoolKey memory poolKey,) = positionManager.getPoolAndPositionInfo(_tokenId);

        // Collect the fees from the position
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        // Call DECREASE_LIQUIDITY with a liquidity of 0 to collect fees
        params[0] = abi.encode(_tokenId, 0, 0, 0, bytes(""));
        // Call TAKE_PAIR to close the open deltas and send the fees to the fee recipient
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1, feeRecipient);

        // Call modifyLiquidity with the actions and params, setting the deadline to the current block
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);

        emit FeesForwarded(feeRecipient);
    }
}
