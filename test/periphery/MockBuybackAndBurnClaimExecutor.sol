// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {MockClaimExecutor} from "./MockClaimExecutor.sol";

/// @title MockBuybackAndBurnClaimExecutor
/// @notice Test executor that makes its configured burn token available to the calling recipient
contract MockBuybackAndBurnClaimExecutor is MockClaimExecutor {
    address public immutable burnToken;
    uint256 public immutable burnAmount;

    constructor(address _burnToken, uint256 _burnAmount) {
        burnToken = _burnToken;
        burnAmount = _burnAmount;
    }

    function callback(PoolKey memory poolKey, uint256 tokenId, uint256 currency0Received, uint256 currency1Received)
        public
        override
    {
        super.callback(poolKey, tokenId, currency0Received, currency1Received);
        IERC20(burnToken).approve(msg.sender, burnAmount);
    }
}
