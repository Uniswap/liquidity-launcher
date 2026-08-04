// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Multicall} from "./Multicall.sol";
import {IAllowanceTransfer, Permit2Forwarder} from "./Permit2Forwarder.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";
import {INativeStrategy} from "./interfaces/INativeStrategy.sol";
import {ILiquidityLauncher} from "./interfaces/ILiquidityLauncher.sol";
import {ITokenFactory} from "@uniswap/uerc20-factory/src/interfaces/ITokenFactory.sol";
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
    ) external payable override returns (address tokenAddress) {
        if (recipient == address(0)) {
            revert RecipientCannotBeZeroAddress();
        }
        tokenAddress = ITokenFactory(factory)
            .createToken(name, symbol, decimals, initialSupply, recipient, tokenData, getGraffiti(msg.sender));

        emit TokenCreated(tokenAddress);
    }

    /// @inheritdoc ILiquidityLauncher
    function depositToken(address token, uint160 amount) external payable override {
        // Pulls tokens from msg.sender via permit2 so the deposit can be batched with `distributeToken`
        // in a single multicall (preceded by a `permit` call for first-time approvals).
        permit2.transferFrom(msg.sender, address(this), amount, token);
    }

    /// @inheritdoc ILiquidityLauncher
    function distributeToken(address token, Distribution calldata distribution, bytes32 salt)
        external
        payable
        override
    {
        // Approve the strategy to pull `distribution.amount` from this contract. The strategy is
        // expected to consume the full allowance via `safeTransferFrom` inside `initializeDistribution`.
        IERC20(token).forceApprove(distribution.strategy, distribution.amount);

        IStrategy(distribution.strategy)
            .initializeDistribution(
                token, distribution.amount, distribution.configData, keccak256(abi.encode(msg.sender, salt))
            );

        // Reject strategies that pull less than the full approved amount.
        if (IERC20(token).allowance(address(this), distribution.strategy) != 0) revert AllowanceNotFullyConsumed();

        emit TokenDistributed(token, distribution.strategy, distribution.amount);
    }

    /// @inheritdoc ILiquidityLauncher
    function distributeWithNative(address strategy, bytes calldata configData, bytes32 salt, uint256 nativeAmount)
        external
        payable
    {
        INativeStrategy(strategy).initializeWithNative{value: nativeAmount}(
            configData, keccak256(abi.encode(msg.sender, salt))
        );

        emit TokenDistributed(address(0), strategy, nativeAmount);
    }

    /// @inheritdoc ILiquidityLauncher
    function getGraffiti(address originalCreator) public pure returns (bytes32 graffiti) {
        graffiti = keccak256(abi.encode(originalCreator));
    }
}
