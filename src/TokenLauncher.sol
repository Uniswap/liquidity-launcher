// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ITokenFactory} from "./token-factories/uerc20-factory/interfaces/ITokenFactory.sol";
import {IDistributionStrategy} from "./interfaces/IDistributionStrategy.sol";
import {IDistributionContract} from "./interfaces/IDistributionContract.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Multicall} from "./Multicall.sol";
import {Distribution} from "./types/Distribution.sol";
import {Permit2Forwarder, IAllowanceTransfer} from "./Permit2Forwarder.sol";
import {ITokenLauncher} from "./interfaces/ITokenLauncher.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title TokenLauncher
/// @notice A contract that allows users to create tokens and distribute them via one or more strategies
contract TokenLauncher is ITokenLauncher, Multicall, Permit2Forwarder {
    using SafeERC20 for IERC20;

    constructor(IAllowanceTransfer _permit2) Permit2Forwarder(_permit2) {}

    /// @inheritdoc ITokenLauncher
    function createToken(
        address factory,
        string calldata name,
        string calldata symbol,
        uint8 decimals,
        uint256 initialSupply,
        address recipient,
        bytes calldata tokenData
    ) external override returns (address tokenAddress) {
        // Create token, with this contract as the recipient of the initial supply
        tokenAddress = ITokenFactory(factory).createToken(
            name, symbol, decimals, initialSupply, recipient, tokenData, getGraffiti(msg.sender)
        );

        emit TokenCreated(tokenAddress);
    }

    /// @inheritdoc ITokenLauncher
    function distributeToken(address token, Distribution calldata distribution, bool payerIsUser)
        external
        override
        returns (IDistributionContract distributionContract)
    {
        // Call the strategy: it might do distributions itself or deploy a new instance.
        // If it does distributions itself, distributionContract == dist.strategy
        distributionContract = IDistributionStrategy(distribution.strategy).initializeDistribution(
            token, distribution.amount, distribution.configData
        );

        // Now transfer the tokens to the returned address
        _transferToken(token, _mapPayer(payerIsUser), address(distributionContract), distribution.amount);

        // Notify the distribution contract that it has received the tokens
        distributionContract.onTokensReceived(token, distribution.amount);

        emit TokenDistributed(token, address(distributionContract), distribution.amount);
    }

    /// @inheritdoc ITokenLauncher
    function getGraffiti(address originalCreator) public pure returns (bytes32 graffiti) {
        graffiti = keccak256(abi.encode(originalCreator));
    }

    /// @notice Transfers tokens to the distribution contract
    /// @param token The address of the token to transfer
    /// @param from The address to transfer the tokens from (this contract or the user)
    /// @param to The distribution contract address to transfer the tokens to
    /// @param amount The amount of tokens to transfer
    function _transferToken(address token, address from, address to, uint256 amount) internal {
        if (from == address(this)) {
            IERC20(token).safeTransfer(to, amount);
        } else {
            permit2.transferFrom(from, to, uint160(amount), token);
        }
    }

    /// @notice Calculates the payer for an action (this contract or the user)
    /// @param payerIsUser Whether the payer is the user
    /// @return payer The address of the payer
    function _mapPayer(bool payerIsUser) internal view returns (address) {
        return payerIsUser ? msg.sender : address(this);
    }
}
