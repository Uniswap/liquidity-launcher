// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IInitializerHook} from "./IInitializerHook.sol";
import {CurvePhase} from "../types/CurvePhase.sol";

/// @notice Typed, per-pool configuration for one bonding-curve launch.
/// @dev This product always pairs native ETH (currency0) against the launched token (currency1), so
///      the curve runs from `curveTickUpper` (initial, highest price) DOWN to `curveTickLower`
///      (graduation, lowest price) as buyers swap ETH for token. There is no `tokenIsCurrency0` flag
///      and no opaque `bytes` — every field is explicit and validated at the single `configure` site.
/// @param reserveTokenAmount Token held by the hook and paired with the completed curve's ETH at graduation.
/// @param finalPositionRecipient Permanent recipient of the graduated full-range LP position.
/// @param graduationSqrtPriceX96 Terminal price; MUST equal getSqrtPriceAtTick(curveTickLower).
/// @param curveTickLower Graduation tick (curve lower bound / terminal price).
/// @param curveTickUpper Initial tick (curve upper bound / starting price).
/// @param swapStartBlock Block from which swaps are allowed; also the fee-decay anchor.
struct BondingCurveConfig {
    uint256 reserveTokenAmount;
    address finalPositionRecipient;
    uint160 graduationSqrtPriceX96;
    int24 curveTickLower;
    int24 curveTickUpper;
    uint48 swapStartBlock;
}

/// @title IBondingCurveHook
/// @notice A v4 hook that runs a token through a single-sided finite curve and, when the curve
///         completes, graduates it in place to full-range liquidity in the same pool.
interface IBondingCurveHook is IInitializerHook {
    /// @notice Emitted when a pool's curve is configured by the authorized launcher.
    event CurveConfigured(PoolId indexed poolId, BondingCurveConfig config);
    /// @notice Emitted when the completed curve begins graduation.
    event GraduationStarted(PoolId indexed poolId);
    /// @notice Emitted when the curve NFT is replaced with a full-range NFT.
    event Graduated(PoolId indexed poolId, uint256 indexed curveTokenId, uint256 indexed finalTokenId, uint256 liquidity);

    error NotAuthorized(address caller, address expected);
    error AlreadyConfigured(PoolId poolId);
    error ZeroAddress();
    error InvalidCurveConfig();
    error InvalidPhaseForSwap(CurvePhase phase);
    error SwapsNotStarted(uint256 swapStartBlock, uint256 currentBlock);
    error InvalidCurvePosition();
    error InvalidPositionManager(address sender);
    error InvalidCurvePositionOwner();
    error InvalidFinalPosition();
    error ExactOutputExceedsCurve(uint256 requested, uint256 available);
    error InvalidGraduationLiquidity(uint128 liquidity);
    error InvalidGraduationPrice(uint160 sqrtPriceX96, uint160 expected);
    error NonzeroNormalizationDelta();
    error UnexpectedPositionManagerDelta(address currency, int256 delta);

    /// @notice Registers a pool's curve config. Callable once per pool by the authorized launcher,
    ///         before pool initialization.
    function configure(PoolId poolId, BondingCurveConfig calldata config) external;

    /// @notice The curve configuration registered for a pool.
    function curveConfig(PoolId poolId) external view returns (BondingCurveConfig memory);
    /// @notice The current lifecycle phase for a pool.
    function phase(PoolId poolId) external view returns (CurvePhase);
    /// @notice The curve NFT held by the hook for a pool.
    function curveTokenId(PoolId poolId) external view returns (uint256);
    /// @notice The v4 PositionManager used for curve and final positions.
    function positionManager() external view returns (IPositionManager);
}
