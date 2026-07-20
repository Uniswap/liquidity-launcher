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
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {BlockNumberish} from "@uniswap/blocknumberish/src/BlockNumberish.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {BondingCurveMath} from "../libraries/BondingCurveMath.sol";
import {PositionPlanner} from "../libraries/PositionPlanner.sol";
import {Plan, Position, CurrencyAmounts} from "../types/PositionPlannerTypes.sol";
import {IBondingCurveLaunchHook, BondingCurveHookConfig} from "../interfaces/IBondingCurveLaunchHook.sol";
import {BuybackAndBurnPositionRecipient} from "../periphery/BuybackAndBurnPositionRecipient.sol";

/// @title BondingCurveLaunchStrategy
/// @notice `IStrategy` that launches a fixed-supply token into a native-ETH bonding-curve v4 pool which
///         graduates in place. Plugs into `LiquidityLauncher.distributeToken`: the launcher approves this
///         strategy and calls `initializeDistribution`, and the strategy pulls the full supply from it.
/// @dev Standalone and single-purpose — no configurable base, no inheritance for reuse. Every pool
///      parameter is fixed at deployment; one instance launches every token at the same price band.
///      Pairs 1B-supply / 18-decimal tokens against native ETH (currency0); the token is always currency1.
/// @custom:security-contact security@uniswap.org
contract BondingCurveLaunchStrategy is IStrategy, BlockNumberish, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice Total token supply required for every launch.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;
    /// @notice Tick spacing used by bonding-curve pools.
    int24 public constant TICK_SPACING = 200;
    /// @notice Minimum token burn required to harvest fees from the graduated position.
    uint256 public constant MIN_TOKEN_BURN = TOTAL_SUPPLY / 2_000;
    /// @notice Sink for burned tokens (unrecoverable).
    address internal constant BURN_ADDRESS = address(0xdead);

    /// @notice Thrown when a caller other than the configured launcher initializes a distribution.
    error OnlyLauncher();
    /// @notice Thrown when caller-supplied configuration is provided.
    error UnexpectedConfigData();
    /// @notice Thrown when the supplied or reported token supply is not fixed.
    error InvalidSupply();
    /// @notice Thrown when the token does not use 18 decimals.
    error InvalidTokenDecimals();
    /// @notice Thrown when the configured ticks cannot define the curve.
    error InvalidTickRange();
    /// @notice Thrown at deployment when the curve supply does not fit in a single position or the
    ///         completed band cannot produce a graduatable position.
    error UnrealizableGraduation();
    /// @notice Thrown when an address required by the strategy is zero.
    error ZeroAddress();
    /// @notice Thrown when the launchHook does not recognize this strategy as its authorized initializer.
    /// @param authorized The launchHook's authorized address
    /// @param expected This strategy's address
    error HookNotBound(address authorized, address expected);
    /// @notice Thrown when the amount received differs from the amount pulled (fee-on-transfer guard).
    /// @param received The amount actually received
    /// @param expected The amount expected
    error TokenAmountMismatch(uint256 received, uint256 expected);

    /// @notice Emitted after the curve pool and permanent LP recipient are created.
    /// @param poolId The identifier of the initialized pool.
    /// @param token The launched token.
    /// @param finalPositionRecipient The permanent recipient of the graduated LP position.
    /// @param curveSupply The token amount placed in the finite curve position.
    /// @param reserveSupply The token amount reserved for full-range graduation.
    event BondingCurveTokenLaunched(
        PoolId indexed poolId,
        address indexed token,
        address indexed finalPositionRecipient,
        uint256 curveSupply,
        uint256 reserveSupply
    );
    /// @notice The only address permitted to drive distributions — set to the canonical LiquidityLauncher
    ///         so launches must route through `distributeToken`.
    address public immutable launcher;
    /// @notice The v4 pool manager.
    IPoolManager public immutable poolManager;
    /// @notice The v4 position manager that mints the curve and graduation positions.
    IPositionManager public immutable positionManager;
    /// @notice The launchHook that gates the curve lifecycle and graduates completed curves.
    IBondingCurveLaunchHook public immutable launchHook;
    /// @notice The dynamic fee module the hook consults for the LP fee while the curve is active.
    ///         Replaceable: deploy a different module and redeploy the strategy pointing at it.
    address public immutable dynamicFeeModule;
    /// @notice Aligned tick at which the curve begins (highest price).
    int24 public immutable initialTick;
    /// @notice Aligned tick at which the curve graduates.
    int24 public immutable graduationTick;
    /// @notice Initial pool square-root price.
    uint160 public immutable initialSqrtPriceX96;
    /// @notice Terminal pool square-root price.
    uint160 public immutable graduationSqrtPriceX96;
    /// @notice Token amount placed in the finite curve position.
    uint256 public immutable curveSupply;
    /// @notice Token amount reserved for full-range graduation.
    uint256 public immutable reserveSupply;
    /// @notice Liquidity of the single-sided curve position.
    uint128 public immutable curveLiquidity;

    constructor(
        address _launcher,
        IPositionManager _positionManager,
        IPoolManager _poolManager,
        IBondingCurveLaunchHook _launchHook,
        address _dynamicFeeModule,
        int24 _initialTick,
        int24 _graduationTick
    ) {
        if (
            _launcher == address(0) || address(_positionManager) == address(0) || address(_poolManager) == address(0)
                || address(_launchHook) == address(0) || _dynamicFeeModule == address(0)
        ) revert ZeroAddress();
        // Ticks must be aligned, usable, and ordered so the curve runs downward from initial to graduation.
        // Graduation is floored at tick 0 (ETH parity for an 18-decimal token): a launch never requires the
        // token to be worth more than ETH, and every permitted band keeps the curve far under maxLiquidityPerTick.
        if (
            _initialTick % TICK_SPACING != 0 || _graduationTick % TICK_SPACING != 0 || _graduationTick < 0
                || _initialTick > TickMath.maxUsableTick(TICK_SPACING) || _graduationTick >= _initialTick
        ) revert InvalidTickRange();

        launcher = _launcher;
        poolManager = _poolManager;
        positionManager = _positionManager;
        launchHook = _launchHook;
        dynamicFeeModule = _dynamicFeeModule;
        initialTick = _initialTick;
        graduationTick = _graduationTick;
        initialSqrtPriceX96 = TickMath.getSqrtPriceAtTick(_initialTick);
        graduationSqrtPriceX96 = TickMath.getSqrtPriceAtTick(_graduationTick);
        (curveSupply, reserveSupply) =
            BondingCurveMath.splitSupply(TOTAL_SUPPLY, initialSqrtPriceX96, graduationSqrtPriceX96, TICK_SPACING);

        // The whole curve supply must fit in one position. Clamping instead would pass the guard below
        // and then silently burn the unplaced remainder of every launch's curve supply as dust.
        uint256 liquidity = FullMath.mulDiv(curveSupply, FixedPoint96.Q96, initialSqrtPriceX96 - graduationSqrtPriceX96);
        if (liquidity > Pool.tickSpacingToMaxLiquidityPerTick(TICK_SPACING)) revert UnrealizableGraduation();
        curveLiquidity = SafeCastLib.toUint128(liquidity);

        // Realizability guard: a completed curve must produce nonzero ETH principal AND a nonzero
        // full-range graduation position, or the pool would brick at the boundary. Reverts at deploy
        // time instead of leaving an un-graduatable band.
        _assertGraduationRealizable();
    }

    /// @inheritdoc IStrategy
    /// @dev Called by `LiquidityLauncher.distributeToken`, which approves `totalSupply` to this strategy
    ///      first. Pulls exactly `totalSupply` from `msg.sender` (fully consuming the allowance, as the
    ///      launcher's post-call guard requires), then builds the curve pool. `configData` must be empty
    ///      and `salt` is unused — this singleton strategy uses fixed parameters.
    function initializeDistribution(address token, uint256 totalSupply, bytes calldata configData, bytes32)
        external
        override
        nonReentrant
    {
        // Only accept distributions routed through the configured launcher.
        if (msg.sender != launcher) revert OnlyLauncher();
        // Verify the launchHook recognizes this strategy (deployed after this contract in the CREATE2 handshake).
        if (launchHook.authorized() != address(this)) revert HookNotBound(launchHook.authorized(), address(this));
        if (configData.length != 0) revert UnexpectedConfigData();
        if (totalSupply != TOTAL_SUPPLY || IERC20(token).totalSupply() != TOTAL_SUPPLY) revert InvalidSupply();
        if (IERC20Metadata(token).decimals() != 18) revert InvalidTokenDecimals();

        uint256 balanceBefore = _pull(token, totalSupply);

        // Permanent, per-token custodian of the graduated LP (timelocked forever; fees harvest-and-burn only).
        BuybackAndBurnPositionRecipient recipient = new BuybackAndBurnPositionRecipient(
            token, address(0), address(0), positionManager, type(uint256).max, MIN_TOKEN_BURN
        );

        // The launchHook custodies the graduation reserve until the curve completes.
        IERC20(token).safeTransfer(address(launchHook), reserveSupply);

        PoolKey memory key = _poolKey(token);
        PoolId poolId = key.toId();

        // Configure before initialize: _beforeInitialize reads the config to pin the opening price.
        launchHook.configure(
            poolId,
            BondingCurveHookConfig({
                reserveTokenAmount: reserveSupply,
                finalPositionRecipient: address(recipient),
                graduationSqrtPriceX96: graduationSqrtPriceX96,
                curveTickLower: graduationTick,
                curveTickUpper: initialTick,
                swapStartBlock: uint48(_getBlockNumberish()),
                module: dynamicFeeModule
            })
        );
        poolManager.initialize(key, initialSqrtPriceX96);

        uint128 tokenTransferAmount = SafeCastLib.toUint128(
            SqrtPriceMath.getAmount1Delta(graduationSqrtPriceX96, initialSqrtPriceX96, curveLiquidity, true)
        );
        Position[] memory positions = new Position[](1);
        positions[0] = Position({
            amount0: 0,
            amount1: tokenTransferAmount,
            tickLower: graduationTick,
            tickUpper: initialTick,
            liquidity: curveLiquidity,
            recipient: address(launchHook)
        });
        Plan memory plan = PositionPlanner.toPlan(positions, key, ActionConstants.MSG_SENDER);

        IERC20(token).safeTransfer(address(positionManager), tokenTransferAmount);
        positionManager.modifyLiquidities(abi.encode(plan.actions, plan.params), block.timestamp);

        // Burn any dust from creating the initial position
        uint256 balanceNow = IERC20(token).balanceOf(address(this));
        if (balanceNow > balanceBefore) IERC20(token).safeTransfer(BURN_ADDRESS, balanceNow - balanceBefore);

        emit DistributionInitialized(address(launchHook), token, totalSupply);
        emit BondingCurveTokenLaunched(poolId, token, address(recipient), curveSupply, reserveSupply);
    }

    /// @notice Pulls exactly `amount` of `token` from `msg.sender`, guarding against callback/FoT tokens
    ///         via a balance-diff check and protecting any pre-existing strategy balance.
    function _pull(address token, uint256 amount) private returns (uint256 balanceBefore) {
        balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - balanceBefore;
        if (received != amount) revert TokenAmountMismatch(received, amount);
    }

    function _poolKey(address token) private view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(launchHook))
        });
    }

    function _assertGraduationRealizable() private view {
        uint256 principal =
            SqrtPriceMath.getAmount0Delta(graduationSqrtPriceX96, initialSqrtPriceX96, curveLiquidity, false);
        Position memory finalPosition = PositionPlanner.resolvePosition(
            PositionPlanner.TickBounds({
                lowerTick: TickMath.minUsableTick(TICK_SPACING), upperTick: TickMath.maxUsableTick(TICK_SPACING)
            }),
            graduationSqrtPriceX96,
            Pool.tickSpacingToMaxLiquidityPerTick(TICK_SPACING),
            CurrencyAmounts({amount0: principal, amount1: reserveSupply}),
            address(0xdead)
        );
        if (principal == 0 || finalPosition.liquidity == 0) revert UnrealizableGraduation();
    }
}
