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
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {BlockNumberish} from "@uniswap/blocknumberish/src/BlockNumberish.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {BondingCurveMath} from "../libraries/BondingCurveMath.sol";
import {PositionPlanner} from "../libraries/PositionPlanner.sol";
import {Position, CurrencyAmounts} from "../types/PositionPlannerTypes.sol";
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
    /// @notice Tick spacing used by all curve pools.
    int24 public constant TICK_SPACING = 200;
    /// @notice Minimum token burn required to harvest fees from the graduated position.
    uint256 public constant MIN_TOKEN_BURN = TOTAL_SUPPLY / 2_000;
    /// @notice Sink for burned tokens (unrecoverable).
    address internal constant BURN_ADDRESS = address(0xdead);

    /// @notice Thrown when a caller other than the configured launcher initializes a distribution.
    error OnlyLauncher();
    /// @notice Thrown when caller-supplied configuration is provided (this strategy uses fixed parameters).
    error UnexpectedConfigData();
    /// @notice Thrown when the supplied or reported token supply is not the required fixed total.
    error InvalidSupply();
    /// @notice Thrown when the launched token does not use 18 decimals.
    error InvalidTokenDecimals();
    /// @notice Thrown when the configured ticks cannot define a valid downward curve.
    error InvalidTickRange();
    /// @notice Thrown at deployment when the tick band cannot produce a graduatable position.
    error UnrealizableGraduation();
    /// @notice Thrown when a required constructor address is zero.
    error ZeroAddress();
    /// @notice Thrown when the launchHook does not recognize this strategy as its authorized initializer.
    /// @param authorized The launchHook's authorized address
    /// @param expected This strategy's address
    error HookNotBound(address authorized, address expected);
    /// @notice Thrown when the amount received differs from the amount pulled (fee-on-transfer guard).
    /// @param received The amount actually received
    /// @param expected The amount expected
    error TokenAmountMismatch(uint256 received, uint256 expected);

    /// @notice Emitted after a curve pool and its permanent LP recipient are created.
    event BondingCurveLaunched(
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

    constructor(
        address _launcher,
        IPositionManager _positionManager,
        IPoolManager _poolManager,
        IBondingCurveLaunchHook _launchHook,
        int24 _initialTick,
        int24 _graduationTick
    ) {
        if (
            _launcher == address(0) || address(_positionManager) == address(0) || address(_poolManager) == address(0)
                || address(_launchHook) == address(0)
        ) revert ZeroAddress();
        // Ticks must be aligned, usable, and ordered so the curve runs downward from initial to graduation.
        if (
            _initialTick % TICK_SPACING != 0 || _graduationTick % TICK_SPACING != 0
                || _graduationTick <= TickMath.minUsableTick(TICK_SPACING)
                || _initialTick > TickMath.maxUsableTick(TICK_SPACING) || _graduationTick >= _initialTick
        ) revert InvalidTickRange();

        launcher = _launcher;
        poolManager = _poolManager;
        positionManager = _positionManager;
        launchHook = _launchHook;
        initialTick = _initialTick;
        graduationTick = _graduationTick;
        initialSqrtPriceX96 = TickMath.getSqrtPriceAtTick(_initialTick);
        graduationSqrtPriceX96 = TickMath.getSqrtPriceAtTick(_graduationTick);
        (curveSupply, reserveSupply) =
            BondingCurveMath.splitSupply(TOTAL_SUPPLY, initialSqrtPriceX96, graduationSqrtPriceX96, TICK_SPACING);

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
                swapStartBlock: uint48(_getBlockNumberish())
            })
        );
        poolManager.initialize(key, initialSqrtPriceX96);

        _mintCurve(key, token);

        // Burn any curve-rounding dust (anything above the pre-existing balance). Returning it to the
        // launcher would re-strand tokens there, which LiquidityLauncher warns are distributable by anyone.
        uint256 balanceNow = IERC20(token).balanceOf(address(this));
        if (balanceNow > balanceBefore) IERC20(token).safeTransfer(BURN_ADDRESS, balanceNow - balanceBefore);

        emit DistributionInitialized(address(launchHook), token, totalSupply);
        emit BondingCurveLaunched(poolId, token, address(recipient), curveSupply, reserveSupply);
    }

    /// @notice Pulls exactly `amount` of `token` from `msg.sender`, guarding against callback/FoT tokens
    ///         via a balance-diff check and protecting any pre-existing strategy balance.
    function _pull(address token, uint256 amount) private returns (uint256 balanceBefore) {
        balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - balanceBefore;
        if (received != amount) revert TokenAmountMismatch(received, amount);
    }

    /// @notice Mints the single-sided curve position `[graduationTick, initialTick]` to the launchHook.
    function _mintCurve(PoolKey memory key, address token) private {
        uint256 liquidity = FullMath.mulDiv(curveSupply, FixedPoint96.Q96, initialSqrtPriceX96 - graduationSqrtPriceX96);
        uint128 maxLiquidity = Pool.tickSpacingToMaxLiquidityPerTick(TICK_SPACING);
        uint128 positionLiquidity = liquidity > maxLiquidity ? maxLiquidity : SafeCastLib.toUint128(liquidity);
        uint128 tokenTransferAmount = SafeCastLib.toUint128(
            SqrtPriceMath.getAmount1Delta(graduationSqrtPriceX96, initialSqrtPriceX96, positionLiquidity, true)
        );

        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE), uint8(Actions.SETTLE), uint8(Actions.TAKE_PAIR)
        );
        bytes[] memory actionParams = new bytes[](4);
        actionParams[0] = abi.encode(
            key,
            graduationTick,
            initialTick,
            positionLiquidity,
            uint128(0),
            tokenTransferAmount,
            address(launchHook),
            bytes("")
        );
        actionParams[1] = abi.encode(key.currency0, ActionConstants.CONTRACT_BALANCE, false);
        actionParams[2] = abi.encode(key.currency1, ActionConstants.CONTRACT_BALANCE, false);
        actionParams[3] = abi.encode(key.currency0, key.currency1, ActionConstants.MSG_SENDER);

        IERC20(token).safeTransfer(address(positionManager), tokenTransferAmount);
        positionManager.modifyLiquidities(abi.encode(actions, actionParams), block.timestamp);
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
        uint256 liquidity = FullMath.mulDiv(curveSupply, FixedPoint96.Q96, initialSqrtPriceX96 - graduationSqrtPriceX96);
        uint128 maxLiquidity = Pool.tickSpacingToMaxLiquidityPerTick(TICK_SPACING);
        uint128 positionLiquidity = liquidity > maxLiquidity ? maxLiquidity : SafeCastLib.toUint128(liquidity);
        uint256 principal =
            SqrtPriceMath.getAmount0Delta(graduationSqrtPriceX96, initialSqrtPriceX96, positionLiquidity, false);
        Position memory finalPosition = PositionPlanner.resolvePosition(
            PositionPlanner.TickBounds({
                lowerTick: TickMath.minUsableTick(TICK_SPACING), upperTick: TickMath.maxUsableTick(TICK_SPACING)
            }),
            graduationSqrtPriceX96,
            maxLiquidity,
            CurrencyAmounts({amount0: principal, amount1: reserveSupply}),
            address(0xdead)
        );
        if (principal == 0 || finalPosition.liquidity == 0) revert UnrealizableGraduation();
    }
}
