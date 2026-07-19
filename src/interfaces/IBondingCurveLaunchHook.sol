// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IInitializerHook} from "./IInitializerHook.sol";

/// @notice Lifecycle of one bonding-curve pool.
/// @dev Ordered so every legal transition is exactly `+1`. Storage default is `Unconfigured`.
///      Unconfigured -> Seeding -> Active -> Graduating -> Graduated; no other edges are legal.
enum BondingCurvePhase {
    Unconfigured,
    Seeding,
    Active,
    Graduating,
    Graduated
}

using {advanceTo} for BondingCurvePhase global;

/// @notice Thrown when a phase transition is not the single legal forward edge.
error IllegalPhaseTransition(BondingCurvePhase from, BondingCurvePhase to);

/// @notice Advances `from` to `to`, reverting unless `to` is the immediate successor of `from`.
/// @dev Centralizes the state machine: the caller writes the returned value back to storage. Because
///      the enum is ordered, "legal" is simply `to == from + 1`, forbidding skips, reversals and self-loops.
function advanceTo(BondingCurvePhase from, BondingCurvePhase to) pure returns (BondingCurvePhase) {
    if (uint8(to) != uint8(from) + 1) revert IllegalPhaseTransition(from, to);
    return to;
}

/// @notice Specialized configuration for one finite curve.
/// @dev This product always pairs native ETH (currency0) against the launched token (currency1), so the
///      curve runs from `curveTickUpper` (initial, highest price) DOWN to `curveTickLower` (graduation,
///      lowest price) as buyers swap ETH for token. Every field is explicit — no `tokenIsCurrency0` flag
///      and no opaque `bytes`.
/// @param reserveTokenAmount The token amount paired with the completed curve proceeds.
/// @param finalPositionRecipient The permanent recipient of the graduated LP position.
/// @param graduationSqrtPriceX96 The terminal pool square-root price.
/// @param curveTickLower The curve position's lower tick (graduation tick).
/// @param curveTickUpper The curve position's upper tick (initial tick).
/// @param swapStartBlock The block from which swaps are allowed; also the fee-decay anchor.
struct BondingCurveHookConfig {
    uint256 reserveTokenAmount;
    address finalPositionRecipient;
    uint160 graduationSqrtPriceX96;
    int24 curveTickLower;
    int24 curveTickUpper;
    uint48 swapStartBlock;
}

/// @title IBondingCurveLaunchHook
/// @notice A v4 hook that runs a token through a single-sided finite curve and, when the curve completes,
///         graduates it in place to full-range liquidity in the same pool.
interface IBondingCurveLaunchHook is IInitializerHook {
    /// @notice Emitted when a pool's curve is configured by the authorized launcher.
    event BondingCurveConfigured(PoolId indexed poolId, BondingCurveHookConfig config);
    /// @notice Emitted when the completed curve enters graduation.
    event GraduationStarted(PoolId indexed poolId);
    /// @notice Emitted when the curve NFT is replaced with a full-range NFT.
    event Graduated(PoolId indexed poolId, uint256 indexed curveTokenId, uint256 indexed finalTokenId, uint256 liquidity);

    /// @notice Thrown when a caller other than the authorized launcher configures a pool.
    /// @param caller The address that attempted the call
    /// @param expected The authorized launcher
    error NotAuthorized(address caller, address expected);
    /// @notice Thrown when a pool's curve has already been configured.
    /// @param poolId The pool that is already configured
    error AlreadyConfigured(PoolId poolId);
    /// @notice Thrown when a required constructor address is zero.
    error ZeroAddress();
    /// @notice Thrown when the supplied curve configuration or pool initialization price is invalid.
    error InvalidBondingCurveConfig();
    /// @notice Thrown when an action is attempted in a phase that does not permit it.
    /// @param phase The current lifecycle phase
    error InvalidBondingCurvePhase(BondingCurvePhase phase);
    /// @notice Thrown when a swap is attempted before the configured swap-start block.
    /// @param swapStartBlock The block at which swaps open
    /// @param currentBlock The current block number
    error SwapsNotStarted(uint256 swapStartBlock, uint256 currentBlock);
    /// @notice Thrown when the seeded liquidity does not match the configured curve position.
    error InvalidCurvePosition();
    /// @notice Thrown when curve or graduation liquidity is not added through the configured PositionManager.
    /// @param sender The unexpected liquidity provider
    error InvalidPositionManager(address sender);
    /// @notice Thrown when the hook does not own the curve NFT it is registering or graduating.
    error InvalidCurvePositionOwner();
    /// @notice Thrown when the graduation position is not full range or resolves to zero liquidity.
    error InvalidFinalPosition();
    /// @notice Thrown when an exact-output buy requests more token than the curve still holds.
    /// @param requested The requested token output
    /// @param available The token remaining in the curve
    error ExactOutputExceedsCurve(uint256 requested, uint256 available);
    /// @notice Thrown when the completed curve still has active liquidity at graduation.
    /// @param liquidity The unexpected active liquidity
    error InvalidGraduationLiquidity(uint128 liquidity);
    /// @notice Thrown when the pool cannot be restored to its configured terminal price for graduation.
    /// @param sqrtPriceX96 The observed price
    /// @param expected The required graduation price
    error InvalidGraduationPrice(uint160 sqrtPriceX96, uint160 expected);
    /// @notice Thrown when normalizing the empty curve range produces a nonzero swap delta.
    error NonzeroNormalizationDelta();
    /// @notice Thrown when the PositionManager holds an unsettled delta before or after graduation.
    /// @param currency The currency with the unexpected delta
    /// @param delta The unsettled delta
    error UnexpectedPositionManagerDelta(address currency, int256 delta);

    /// @notice Registers a pool's curve config. Callable once per pool by the authorized launcher,
    ///         before pool initialization.
    /// @param poolId The pool the configuration applies to
    /// @param config The curve configuration to register
    function configure(PoolId poolId, BondingCurveHookConfig calldata config) external;

    /// @notice Returns the curve configuration registered for a pool.
    function bondingCurveConfig(PoolId poolId) external view returns (BondingCurveHookConfig memory);
    /// @notice Returns the current lifecycle phase for a pool.
    function bondingCurvePhase(PoolId poolId) external view returns (BondingCurvePhase);
    /// @notice Returns the curve NFT held by the hook for a pool.
    function curveTokenId(PoolId poolId) external view returns (uint256);
    /// @notice Returns the v4 PositionManager used for curve and final positions.
    function positionManager() external view returns (IPositionManager);
}
