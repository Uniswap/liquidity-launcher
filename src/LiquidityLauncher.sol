// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Multicall} from "./Multicall.sol";
import {IAllowanceTransfer, Permit2Forwarder} from "./Permit2Forwarder.sol";
import {IDistributionContract} from "./interfaces/IDistributionContract.sol";
import {IDistributionStrategy} from "./interfaces/IDistributionStrategy.sol";
import {ILiquidityLauncher} from "./interfaces/ILiquidityLauncher.sol";
import {ITokenFactory} from "uerc20-factory/src/interfaces/ITokenFactory.sol";
import {Distribution} from "./types/Distribution.sol";

/// @title LiquidityLauncher
/// @notice A contract that allows users to create tokens and distribute them via one or more strategies
/// @custom:security-contact security@uniswap.org
contract LiquidityLauncher is ILiquidityLauncher, Multicall, Permit2Forwarder {
    using SafeERC20 for IERC20;

    constructor(IAllowanceTransfer _permit2) Permit2Forwarder(_permit2) {}

    /// @inheritdoc ILiquidityLauncher
    function createToken(
        address factory,
        string calldata name,
        string calldata symbol,
        uint8 decimals,
        uint128 initialSupply,
        address recipient,
        bytes calldata tokenData
    ) external override returns (address tokenAddress) {
        if (recipient == address(0)) {
            revert RecipientCannotBeZeroAddress();
        }
        tokenAddress = ITokenFactory(factory)
            .createToken(name, symbol, decimals, initialSupply, recipient, tokenData, getGraffiti(msg.sender));

        emit TokenCreated(tokenAddress);
    }

    /// @inheritdoc ILiquidityLauncher
    function distributeToken(address token, Distribution calldata distribution, bool payerIsUser, bytes32 salt)
        external
        override
        returns (IDistributionContract distributionContract)
    {
        // Call the strategy: it might do distributions itself or deploy a new instance.
        // If it does distributions itself, distributionContract == dist.strategy
        distributionContract = IDistributionStrategy(distribution.strategy)
            .initializeDistribution(
                token, distribution.amount, distribution.configData, keccak256(abi.encode(msg.sender, salt))
            );

        // Now transfer the tokens to the returned address
        // payerIsUser should be false if the tokens were created in the same call via multicall
        _transferToken(token, _mapPayer(payerIsUser), address(distributionContract), distribution.amount);

        // Notify the distribution contract that it has received the tokens
        distributionContract.onTokensReceived();

        emit TokenDistributed(token, address(distributionContract), distribution.amount);
    }

    /// @inheritdoc ILiquidityLauncher
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
