// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {IFeeSplitter} from "../interfaces/IFeeSplitter.sol";
import {PositionPlanner} from "../libraries/PositionPlanner.sol";
import {Plan, Position, CurrencyAmounts, PositionDefinition} from "../types/PositionPlannerTypes.sol";

/// @title DirectLaunchStrategy
/// @notice `IStrategy` that launches a fixed-supply token directly into a hookless native-ETH v4 pool,
///         with the entire supply in a single-sided LP position. Plugs into `LiquidityLauncher.distributeToken`:
///         the launcher approves this strategy and calls `initializeDistribution`, and the strategy pulls
///         the full supply from it.
/// @dev Standalone and single-purpose, with no graduation or hook. Every pool parameter is fixed at
///      deployment; one instance launches every token at the same price band. Pairs 1B-supply /
///      18-decimal tokens against native ETH (currency0); the token is always currency1. The position spans
///      from the min usable tick up to the initial tick — the token side of the opening price — so buys walk
///      the price downward through the available supply.
/// @custom:security-contact security@uniswap.org
contract DirectLaunchStrategy is IStrategy, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using PositionPlanner for *;

    /// @notice Total token supply required for every launch.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;
    /// @notice Static LP fee of 25 bps
    uint24 public constant LP_FEE = 2_500;
    /// @notice Tick spacing
    int24 public constant TICK_SPACING = 60;
    /// @notice Sink for burned tokens (unrecoverable).
    address internal constant BURN_ADDRESS = address(0xdead);

    /// @notice The only address permitted to drive distributions — set to the canonical LiquidityLauncher
    ///         so launches must route through `distributeToken`.
    address public immutable launcher;
    /// @notice The v4 position manager that mints the launch position.
    IPositionManager public immutable positionManager;
    /// @notice The v4 pool manager.
    IPoolManager public immutable poolManager;
    /// @notice The singleton fee splitter that permanently holds every launch position and
    ///         permissionlessly distributes its fees.
    IFeeSplitter public immutable feeSplitter;
    /// @notice Aligned tick at which the pool opens (highest price); the position's upper bound.
    int24 public immutable initialTick;
    /// @notice Initial pool square-root price.
    uint160 public immutable initialSqrtPriceX96;
    /// @notice Liquidity of the single-sided launch position holding the full supply.
    uint128 public immutable positionLiquidity;

    /// @notice Thrown when an address required by the strategy is zero.
    error ZeroAddress();
    /// @notice Thrown when a caller other than the configured launcher initializes a distribution.
    error OnlyLauncher();
    /// @notice Thrown when caller-supplied configuration is provided.
    error UnexpectedConfigData();
    /// @notice Thrown when the supplied or reported token supply is not fixed.
    error InvalidSupply();
    /// @notice Thrown when the token does not use 18 decimals.
    error InvalidTokenDecimals();
    /// @notice Thrown when the configured tick cannot define the launch range.
    error InvalidTickRange();
    /// @notice Thrown when the fee splitter is not bound to the same PositionManager as this strategy.
    /// @param splitterPositionManager The fee splitter's PositionManager
    error FeeSplitterMismatch(address splitterPositionManager);
    /// @notice Thrown at deployment when the full supply does not fit in a single position.
    error UnrealizableLaunch();
    /// @notice Thrown when the plan does not resolve to exactly the precomputed launch position.
    error InvalidPositions();
    /// @notice Thrown when the amount received differs from the amount pulled (fee-on-transfer guard).
    /// @param received The amount actually received
    /// @param expected The amount expected
    error TokenAmountMismatch(uint256 received, uint256 expected);

    /// @notice Emitted when a token is launched.
    /// @param poolId The identifier of the initialized pool.
    /// @param token The launched token.
    /// @param finalPositionRecipient The permanent recipient of the launch LP position.
    /// @param key The initialized pool key.
    event TokenLaunched(
        PoolId indexed poolId, address indexed token, address indexed finalPositionRecipient, PoolKey key
    );

    constructor(
        address _launcher,
        IPositionManager _positionManager,
        IPoolManager _poolManager,
        IFeeSplitter _feeSplitter,
        int24 _initialTick
    ) {
        if (
            _launcher == address(0) || address(_positionManager) == address(0) || address(_poolManager) == address(0)
                || address(_feeSplitter) == address(0)
        ) {
            revert ZeroAddress();
        }
        // The splitter collects through its own PositionManager; a mismatch would leave every
        // launch position's fees permanently uncollectable.
        if (_feeSplitter.positionManager() != _positionManager) {
            revert FeeSplitterMismatch(address(_feeSplitter.positionManager()));
        }
        // The tick must be aligned and leave a non-empty usable range below it: the launch position spans
        // [minUsableTick, initialTick] on the token side of the price.
        if (
            _initialTick % TICK_SPACING != 0 || _initialTick > TickMath.maxUsableTick(TICK_SPACING)
                || _initialTick <= TickMath.minUsableTick(TICK_SPACING)
        ) revert InvalidTickRange();

        launcher = _launcher;
        poolManager = _poolManager;
        positionManager = _positionManager;
        feeSplitter = _feeSplitter;
        initialTick = _initialTick;
        initialSqrtPriceX96 = TickMath.getSqrtPriceAtTick(_initialTick);

        // The whole supply must fit in one position. Clamping instead would pass the resolve step below
        // and then silently burn the unplaced remainder of every launch's supply as dust.
        uint256 liquidity = FullMath.mulDiv(
            TOTAL_SUPPLY,
            FixedPoint96.Q96,
            initialSqrtPriceX96 - TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(TICK_SPACING))
        );
        if (liquidity > Pool.tickSpacingToMaxLiquidityPerTick(TICK_SPACING)) revert UnrealizableLaunch();
        positionLiquidity = SafeCastLib.toUint128(liquidity);
    }

    /// @inheritdoc IStrategy
    /// @dev Called by `LiquidityLauncher.distributeToken`, which approves `totalSupply` to this strategy
    ///      first. Pulls exactly `totalSupply` from `msg.sender` (fully consuming the allowance, as the
    ///      launcher's post-call guard requires), then builds the launch pool. `configData` must be empty
    ///      and `salt` is unused — this singleton strategy uses fixed parameters.
    function initializeDistribution(address token, uint256 totalSupply, bytes calldata configData, bytes32)
        external
        override
        nonReentrant
    {
        // Only accept distributions routed through the configured launcher.
        if (msg.sender != launcher) revert OnlyLauncher();
        if (configData.length != 0) revert UnexpectedConfigData();
        if (totalSupply != TOTAL_SUPPLY || IERC20(token).totalSupply() != TOTAL_SUPPLY) revert InvalidSupply();
        if (IERC20Metadata(token).decimals() != 18) revert InvalidTokenDecimals();

        uint256 balanceBefore = _pull(token, totalSupply);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        PoolId poolId = key.toId();

        // Will revert if the pool is already initialized.
        poolManager.initialize(key, initialSqrtPriceX96);

        Plan memory plan;
        {
            PositionDefinition[] memory definitions = new PositionDefinition[](1);
            definitions[0] = PositionDefinition({
                // The token is currency1, so its single-sided range sits below the opening price:
                // from the min usable tick up to the initial tick.
                offsetLower: TickMath.minUsableTick(TICK_SPACING) - initialTick,
                offsetUpper: 0,
                weight: PositionPlanner.MPS,
                overridePositionRecipient: address(0)
            });

            definitions.validate();
            // The position is minted to the fee splitter: permanent custody, permissionless
            // per-pool fee distribution (see FeeSplitter).
            (Position[] memory positions,) = definitions.resolve(
                initialSqrtPriceX96,
                TICK_SPACING,
                CurrencyAmounts({amount0: 0, amount1: TOTAL_SUPPLY}),
                address(feeSplitter)
            );
            // Exactly the precomputed uncapped position: anything else means part of the supply
            // was left unplaced, and the sub-liquidity-unit rounding dust is burned below.
            if (positions.length != 1 || positions[0].liquidity != positionLiquidity) revert InvalidPositions();

            plan = positions.toPlan(key, ActionConstants.MSG_SENDER);
        }

        IERC20(token).safeTransfer(address(positionManager), TOTAL_SUPPLY);
        positionManager.modifyLiquidities(abi.encode(plan.actions, plan.params), block.timestamp);

        // Burn any dust from creating the initial position
        uint256 balanceNow = IERC20(token).balanceOf(address(this));
        if (balanceNow > balanceBefore) IERC20(token).safeTransfer(BURN_ADDRESS, balanceNow - balanceBefore);

        emit DistributionInitialized(address(this), token, totalSupply);
        emit TokenLaunched(poolId, token, address(feeSplitter), key);
    }

    /// @notice Pulls exactly `amount` of `token` from `msg.sender`, guarding against callback/FoT tokens
    ///         via a balance-diff check and protecting any pre-existing strategy balance.
    function _pull(address token, uint256 amount) private returns (uint256 balanceBefore) {
        balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - balanceBefore;
        if (received != amount) revert TokenAmountMismatch(received, amount);
    }
}
