// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ILaunchHook} from "./ILaunchHook.sol";

/// @notice Lifecycle of one bonding-curve pool.
enum BondingCurvePhase {
    Unconfigured,
    Seeding,
    Active,
    Graduating,
    Graduated
}

/// @notice Specialized configuration for one finite curve.
/// @param manager The per-launch contract authorized to begin graduation.
/// @param graduationSqrtPriceX96 The terminal pool square-root price.
/// @param curveTickLower The curve position's lower tick.
/// @param curveTickUpper The curve position's upper tick.
struct BondingCurveHookConfig {
    address manager;
    uint160 graduationSqrtPriceX96;
    int24 curveTickLower;
    int24 curveTickUpper;
}

/// @title IBondingCurveLaunchHook
/// @notice Freezes completed curve pools and restricts liquidity until graduation
interface IBondingCurveLaunchHook is ILaunchHook {
    /// @notice Emitted when a pool's curve lifecycle is configured.
    event BondingCurveConfigured(PoolId indexed poolId, BondingCurveHookConfig config);
    /// @notice Emitted when the completed curve enters graduation.
    event GraduationStarted(PoolId indexed poolId);
    /// @notice Emitted when the full-range position completes graduation.
    event GraduationCompleted(PoolId indexed poolId);

    /// @notice Thrown when specialized hook configuration is invalid.
    error InvalidBondingCurveConfig();
    /// @notice Thrown when an action is unavailable in the pool's current phase.
    error InvalidBondingCurvePhase(BondingCurvePhase phase);
    /// @notice Thrown when initial liquidity does not match the configured curve.
    error InvalidCurvePosition();
    /// @notice Thrown when graduation liquidity is not full range.
    error InvalidFinalPosition();
    /// @notice Thrown when the caller is not the pool's graduation manager.
    error InvalidGraduationManager(address caller, address expected);
    /// @notice Thrown when a buy price limit can cross the terminal price.
    error InvalidBuyPriceLimit(uint160 limit, uint160 graduationSqrtPriceX96);
    /// @notice Thrown when swaps are frozen pending graduation.
    error GraduationPending();
    /// @notice Thrown when graduation is attempted before the terminal price.
    error GraduationNotReady();

    /// @notice Returns the specialized curve configuration for a pool.
    function bondingCurveConfig(PoolId poolId) external view returns (BondingCurveHookConfig memory);
    /// @notice Returns the current lifecycle phase for a pool.
    function bondingCurvePhase(PoolId poolId) external view returns (BondingCurvePhase);
    /// @notice Freezes graduation state before the manager replaces the curve position.
    /// @dev May only be called by the configured manager at the exact terminal price.
    function beginGraduation(PoolKey calldata key) external;
}
