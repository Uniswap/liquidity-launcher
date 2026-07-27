// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IClaimExecutor} from "../../src/interfaces/IClaimExecutor.sol";
import {IClaimableRecipient} from "../../src/interfaces/IClaimableRecipient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title MockClaimExecutor
contract MockClaimExecutor is IClaimExecutor {
    uint256 public lastTokenId;
    uint256 public lastCurrency0Received;
    uint256 public lastCurrency1Received;

    function execute(
        IClaimableRecipient recipient,
        uint256 tokenId,
        uint256 minCurrency0Amount,
        uint256 minCurrency1Amount
    ) external {
        recipient.claim(tokenId, minCurrency0Amount, minCurrency1Amount);
    }

    function approveToken(address token, address spender, uint256 amount) external {
        IERC20(token).approve(spender, amount);
    }

    function onClaimed(PoolKey memory, uint256 tokenId, uint256 currency0Received, uint256 currency1Received)
        public
        virtual
    {
        lastTokenId = tokenId;
        lastCurrency0Received = currency0Received;
        lastCurrency1Received = currency1Received;
    }

    function supportsInterface(bytes4 interfaceId) public view virtual returns (bool) {
        return interfaceId == type(IClaimExecutor).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    receive() external payable {}
}
