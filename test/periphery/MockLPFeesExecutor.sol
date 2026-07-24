// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ILPFeesExecutor} from "../../src/interfaces/ILPFeesExecutor.sol";
import {ILPFeesPositionRecipient} from "../../src/interfaces/ILPFeesPositionRecipient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title MockLPFeesExecutor
contract MockLPFeesExecutor is ILPFeesExecutor {
    uint256 public lastTokenId;
    uint256 public lastCurrency0Received;
    uint256 public lastCurrency1Received;

    function execute(
        ILPFeesPositionRecipient recipient,
        uint256 tokenId,
        uint256 minCurrency0Amount,
        uint256 minCurrency1Amount
    ) external {
        recipient.collectFees(tokenId, minCurrency0Amount, minCurrency1Amount);
    }

    function approveToken(address token, address spender, uint256 amount) external {
        IERC20(token).approve(spender, amount);
    }

    function onFeesCollected(PoolKey memory, uint256 tokenId, uint256 currency0Received, uint256 currency1Received)
        public
        virtual
    {
        lastTokenId = tokenId;
        lastCurrency0Received = currency0Received;
        lastCurrency1Received = currency1Received;
    }

    receive() external payable {}
}
