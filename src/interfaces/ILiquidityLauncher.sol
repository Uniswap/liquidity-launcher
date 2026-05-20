// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Distribution} from "../types/Distribution.sol";
import {IDistributionContract} from "./IDistributionContract.sol";

/// @title ILiquidityLauncher
/// @notice Interface for the LiquidityLauncher contract
interface ILiquidityLauncher {
    /// @notice Thrown when the recipient is the zero address
    error RecipientCannotBeZeroAddress();

    /// @notice Emitted when a token is created
    /// @param tokenAddress The address of the token that was created
    event TokenCreated(address indexed tokenAddress);

    /// @notice Emitted when a token is distributed
    /// @param tokenAddress The address of the token that was distributed
    /// @param distributionContract The address of the distribution contract
    /// @param amount The amount of tokens that were distributed
    event TokenDistributed(address indexed tokenAddress, address indexed distributionContract, uint256 amount);

    /// @notice Creates a token via the configured factory.
    /// @dev When `recipient == address(this)`, the newly minted tokens are held in the launcher
    ///      and ANY caller can subsequently invoke `distributeToken` on them with arbitrary strategy
    ///      parameters. ONLY pass `address(this)` when this call is batched with `distributeToken`
    ///      in the SAME `multicall`
    /// @param factory Address of the factory to use
    /// @param name Token name
    /// @param symbol Token symbol
    /// @param decimals Token decimals
    /// @param initialSupply Total tokens to be minted
    /// @param recipient The address that will receive the newly minted tokens. See @dev above for the
    ///                  safety implications of passing `address(this)`.
    /// @param tokenData Extra data needed by the factory
    /// @return tokenAddress The address of the token that was created
    function createToken(
        address factory,
        string calldata name,
        string calldata symbol,
        uint8 decimals,
        uint128 initialSupply,
        address recipient,
        bytes calldata tokenData
    ) external returns (address tokenAddress);

    /// @notice Pulls `amount` of `token` from `msg.sender` into this contract via Permit2.
    /// @dev Intended to be batched with `distributeToken` inside `multicall` so the deposited tokens
    ///      cannot be picked up by another caller. Requires the user to have set up a Permit2 allowance
    ///      for this contract
    /// @param token The token to pull
    /// @param amount The amount to pull (uint160 — Permit2 allowance type)
    function depositToken(address token, uint160 amount) external;

    /// @notice Distribute tokens already held by this contract via one or more strategies
    /// @dev The launcher must already hold `distribution.amount` of `tokenAddress`. The launcher
    ///      approves the strategy for that amount; the strategy is expected to pull the full amount
    ///      via `safeTransferFrom` inside its `initializeDistribution` call.
    ///      Always batch token-acquisition (`createToken` or `depositToken`) and `distributeToken`
    ///      in a single `multicall`
    /// @param tokenAddress The address of the token to distribute
    /// @param distribution Distribution instructions
    /// @param salt The salt to pass into the distribution strategy contract if needed
    /// @return distributionContract The address of the distribution contract
    function distributeToken(address tokenAddress, Distribution memory distribution, bytes32 salt)
        external
        returns (IDistributionContract distributionContract);

    /// @notice Calculates the graffiti that will be used for a token creation
    /// @param originalCreator The address that will be set as the original creator
    /// @return graffiti The graffiti bytes32 that will be used
    function getGraffiti(address originalCreator) external view returns (bytes32 graffiti);
}
