// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
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
/// @param reserveTokenAmount The token amount paired with the completed curve proceeds.
/// @param finalPositionRecipient The permanent recipient of the graduated LP position.
/// @param graduationSqrtPriceX96 The terminal pool square-root price.
/// @param curveTickLower The curve position's lower tick.
/// @param curveTickUpper The curve position's upper tick.
struct BondingCurveHookConfig {
    uint256 reserveTokenAmount;
    address finalPositionRecipient;
    uint160 graduationSqrtPriceX96;
    int24 curveTickLower;
    int24 curveTickUpper;
}

/// @title IBondingCurveLaunchHook
/// @notice Graduates completed curve pools and restricts liquidity throughout their lifecycle
interface IBondingCurveLaunchHook is ILaunchHook {
    /// @notice Emitted when a pool's curve lifecycle is configured.
    event BondingCurveConfigured(PoolId indexed poolId, BondingCurveHookConfig config);
    /// @notice Emitted when the completed curve enters graduation.
    event GraduationStarted(PoolId indexed poolId);
    /// @notice Emitted when the curve NFT is replaced with a full-range NFT.
    event Graduated(
        PoolId indexed poolId, uint256 indexed curveTokenId, uint256 indexed finalTokenId, uint256 liquidity
    );

    /// @notice Thrown when specialized hook configuration is invalid.
    error InvalidBondingCurveConfig();
    /// @notice Thrown when the configured PositionManager is zero.
    error ZeroAddress();
    /// @notice Thrown when an action is unavailable in the pool's current phase.
    error InvalidBondingCurvePhase(BondingCurvePhase phase);
    /// @notice Thrown when initial liquidity does not match the configured curve.
    error InvalidCurvePosition();
    /// @notice Thrown when the curve position is not added through the configured PositionManager.
    error InvalidPositionManager(address sender);
    /// @notice Thrown when the hook does not own the curve NFT being registered.
    error InvalidCurvePositionOwner();
    /// @notice Thrown when graduation liquidity is not full range.
    error InvalidFinalPosition();
    /// @notice Thrown when an exact-output buy requests more tokens than remain in the curve.
    error ExactOutputExceedsCurve(uint256 requested, uint256 available);
    /// @notice Thrown when the completed curve still has active liquidity.
    error InvalidGraduationLiquidity(uint128 liquidity);
    /// @notice Thrown when normalizing an empty range produces a nonzero swap delta.
    error NonzeroNormalizationDelta();
    /// @notice Thrown when the pool cannot be restored to its configured terminal price.
    error InvalidGraduationPrice(uint160 sqrtPriceX96, uint160 expected);
    /// @notice Thrown when the final position does not complete the graduation callback.
    error GraduationIncomplete();

    /// @notice Returns the specialized curve configuration for a pool.
    function bondingCurveConfig(PoolId poolId) external view returns (BondingCurveHookConfig memory);
    /// @notice Returns the current lifecycle phase for a pool.
    function bondingCurvePhase(PoolId poolId) external view returns (BondingCurvePhase);
    /// @notice Returns the curve NFT held by the hook for a pool.
    function curveTokenId(PoolId poolId) external view returns (uint256);
    /// @notice Returns the v4 PositionManager used for curve and final LP positions.
    function positionManager() external view returns (IPositionManager);
}
