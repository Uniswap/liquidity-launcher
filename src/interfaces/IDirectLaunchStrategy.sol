// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IStrategy} from "./IStrategy.sol";

/// @title IDirectLaunchStrategy
/// @notice Interface for the DirectLaunchStrategy contract
interface IDirectLaunchStrategy is IStrategy {
    /// @notice Emitted when a token is launched into a freshly initialized v4 pool
    /// @param poolId The id of the initialized pool
    /// @param token The launched token
    /// @param key The key of the initialized pool
    /// @param initialSqrtPriceX96 The initial sqrt price of the pool
    /// @param plan The PositionManager plan executed to mint the positions
    event TokenLaunched(
        PoolId indexed poolId, address indexed token, PoolKey key, uint160 initialSqrtPriceX96, bytes plan
    );

    /// @notice Emitted when unplaced tokens are swept
    /// @param recipient The recipient that received the swept tokens
    /// @param amount The amount of tokens swept
    event TokensSwept(address indexed recipient, uint256 amount);

    /// @notice Error thrown when the token is the zero address
    error ZeroAddressToken();

    /// @notice Error thrown when the launched token and pool currency are the same
    /// @param token The address configured as both token and currency
    error InvalidTokenCurrencyPair(address token);

    /// @notice Error thrown when the tick spacing is greater than the max tick spacing or less than the min tick spacing
    /// @param tickSpacing The invalid tick spacing
    error InvalidTickSpacing(int24 tickSpacing, int24 minTickSpacing, int24 maxTickSpacing);

    /// @notice Error thrown when the fee is greater than the max fee
    /// @param fee The invalid fee
    error InvalidFee(uint24 fee, uint24 maxFee);

    /// @notice Error thrown when dynamic LP fees are configured without a hook
    error InvalidDynamicFeeHook();

    /// @notice Error thrown when the recipient of unplaced tokens is the zero address
    error InvalidRecipient();

    /// @notice Error thrown when a position recipient is the zero address, address(1), or address(2)
    /// @param recipient The invalid position recipient
    error InvalidPositionRecipient(address recipient);

    /// @notice Error thrown when the position definition weights do not sum to exactly 1e7 (100% in mps)
    /// @param totalWeight The invalid total weight
    error IncompleteAllocation(uint256 totalWeight);

    /// @notice Error thrown when no positions are created during launch
    error NoPositionsCreated();

    /// @notice Error thrown when the token amount received does not match the amount pulled
    /// @param actual The actual amount of token received
    /// @param expected The expected amount of token
    error TokenAmountMismatch(uint256 actual, uint256 expected);

    /// @notice Error thrown when the configured hook supports ILaunchHook but no launch config was supplied
    error MissingLaunchConfig();

    /// @notice Error thrown when a launch config was supplied but the configured hook does not support ILaunchHook
    error UnexpectedLaunchConfig();
}
