// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {ITokenSplitter} from "../interfaces/ITokenSplitter.sol";

/// @title TokenSplitter
/// @notice A minimal strategy that splits a distribution across N recipients (e.g. EOAs / multisigs).
/// @dev The caller must approve this strategy for at least `totalSupply` of `token` before calling.
///      Tokens are pulled directly from the caller to each recipient, so this contract never custodies funds.
///      The sum of split amounts MUST equal `totalSupply`, which fully consumes the caller's allowance.
/// @custom:security-contact security@uniswap.org
contract TokenSplitter is ITokenSplitter {
    using SafeERC20 for IERC20;

    /// @inheritdoc IStrategy
    function initializeDistribution(address token, uint256 totalSupply, bytes calldata configData, bytes32)
        external
        override
    {
        Split[] memory splits = abi.decode(configData, (Split[]));
        uint256 length = splits.length;
        if (length == 0) revert NoSplits();

        uint256 distributed;
        for (uint256 i = 0; i < length; i++) {
            address recipient = splits[i].recipient;
            uint256 amount = splits[i].amount;
            if (recipient == address(0)) revert ZeroRecipient();
            if (amount == 0) revert ZeroAmount();
            distributed += amount;
            IERC20(token).safeTransferFrom(msg.sender, recipient, amount);
        }

        // Must equal totalSupply so the caller's allowance is fully consumed.
        if (distributed != totalSupply) revert InvalidSplit(distributed, totalSupply);

        emit TokensSplit(token, totalSupply, length);
    }
}
