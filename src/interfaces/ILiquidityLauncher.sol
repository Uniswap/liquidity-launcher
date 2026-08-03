// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Distribution} from "../types/Distribution.sol";

/// @title ILiquidityLauncher
/// @notice Interface for the LiquidityLauncher contract
interface ILiquidityLauncher {
    /// @notice Thrown when the recipient is the zero address
    error RecipientCannotBeZeroAddress();

    /// @notice Thrown when the strategy did not consume the full pre-approved allowance.
    error AllowanceNotFullyConsumed();

    /// @notice Emitted when a token is created
    /// @param tokenAddress The address of the token that was created
    event TokenCreated(address indexed tokenAddress);

    /// @notice Emitted when a token is distributed
    /// @param tokenAddress The address of the token that was distributed
    /// @param strategy The strategy that pulled the distributed tokens
    /// @param amount The amount of tokens that were distributed
    event TokenDistributed(address indexed tokenAddress, address indexed strategy, uint256 amount);

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
    ) external payable returns (address tokenAddress);

    /// @notice Pulls `amount` of `token` from `msg.sender` into this contract via Permit2.
    /// @dev Intended to be batched with `distributeToken` inside `multicall` so the deposited tokens
    ///      cannot be picked up by another caller. Requires the user to have set up a Permit2 allowance
    ///      for this contract
    /// @param token The token to pull
    /// @param amount The amount to pull (uint160 — Permit2 allowance type)
    function depositToken(address token, uint160 amount) external payable;

    /// @notice Distribute tokens already held by this contract via one or more strategies
    /// @dev The launcher must already hold `distribution.amount` of `tokenAddress`. The launcher
    ///      approves the strategy for that amount; the strategy is expected to pull the full amount
    ///      via `safeTransferFrom` inside its `initializeDistribution` call.
    ///      Always batch token-acquisition (`createToken` or `depositToken`) and `distributeToken`
    ///      in a single `multicall`
    /// @param tokenAddress The address of the token to distribute
    /// @param distribution Distribution instructions
    /// @param salt The salt to pass into the strategy contract if needed
    function distributeToken(address tokenAddress, Distribution memory distribution, bytes32 salt) external payable;

    /// @notice Runs a strategy that spends native instead of a distributed token
    /// @dev Forwards `nativeAmount` with the call. There is no token leg, so nothing is approved.
    /// @param strategy The strategy to run
    /// @param configData Arbitrary, strategy-specific parameters
    /// @param salt Domain separator, hashed together with the caller
    /// @param nativeAmount The native to forward with the call
    function distributeWithNative(address strategy, bytes calldata configData, bytes32 salt, uint256 nativeAmount)
        external
        payable;

    /// @notice Sends native held by this contract to `recipient`
    /// @dev A batch must end with this whenever it carries more native than it forwards, since `multicall`
    ///      rejects native left behind.
    /// @param recipient The receiver of the native
    function sweepNative(address recipient) external payable;

    /// @notice Calculates the graffiti that will be used for a token creation
    /// @param originalCreator The address that will be set as the original creator
    /// @return graffiti The graffiti bytes32 that will be used
    function getGraffiti(address originalCreator) external view returns (bytes32 graffiti);
}
