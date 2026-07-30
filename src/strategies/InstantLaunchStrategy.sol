// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {IBeneficiaryVault} from "../interfaces/IBeneficiaryVault.sol";
import {IFeeSplitter} from "../interfaces/IFeeSplitter.sol";
import {PositionPlanner} from "../libraries/PositionPlanner.sol";
import {Plan, Position, CurrencyAmounts, PositionDefinition} from "../types/PositionPlannerTypes.sol";

/// @notice The launch configuration carried in `configData`.
/// @param feeBeneficiary The freely chosen recipient of the fee splitter's beneficiary share.
struct InstantLaunchConfig {
    address feeBeneficiary;
}

/// @title InstantLaunchStrategy
/// @notice `IStrategy` that launches a fixed-supply token directly into a hookless native-ETH v4 pool,
///         with the entire supply in a single-sided LP position. Plugs into `LiquidityLauncher.distributeToken`:
///         the launcher approves this strategy and calls `initializeDistribution`, and the strategy pulls
///         the full supply from it.
/// @dev Standalone and single-purpose, with no graduation or hook. Every pool parameter is fixed at
///      deployment; one instance launches every token at the same price band. Pairs 1B-supply /
///      18-decimal tokens against native ETH (currency0); the token is always currency1. The position spans
///      from `MIN_LAUNCH_TICK` up to the initial tick — the token side of the opening price — so buys walk
///      the price downward through the available supply.
/// @custom:security-contact security@uniswap.org
contract InstantLaunchStrategy is IStrategy, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using PositionPlanner for *;

    /// @notice Total token supply required for every launch.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;
    /// @notice Static LP fee of 25 bps
    uint24 public constant LP_FEE = 2_500;
    /// @notice Tick spacing
    int24 public constant TICK_SPACING = 60;
    /// @notice Lower tick of every launch position, and the exclusive floor for `initialTick`.
    /// @dev Filling a tick's `maxLiquidityPerTick` blocks every later liquidity increase on a position
    ///      bounded by it, which strands the fees of any compounding recipient. This is the lowest aligned
    ///      tick at which doing so costs more than `TOTAL_SUPPLY` for every `initialTick` the constructor
    ///      accepts, so it cannot be funded at any price. The constructor proves the property rather than
    ///      trusting this value; deeper floors are cheaper to fill and are rejected there.
    int24 public constant MIN_LAUNCH_TICK = -195_120;
    /// @notice Native an attacker must post to fill a boundary tick's allowance, below which a launch is
    ///         rejected.
    /// @dev The native-side counterpart to "more than the token supply would be needed": on the order of
    ///      the entire circulating ETH supply, so the native door is unfundable rather than merely costly.
    uint256 public constant MIN_NATIVE_PIN_COST = 120_000_000 ether;
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
    /// @notice The vault that registers each launch's fee beneficiary and vaults their fee share.
    ///         Zero when this instance launches without a creator fee share.
    IBeneficiaryVault public immutable beneficiaryVault;
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
    /// @notice Thrown when the launch configuration is missing.
    error InvalidConfigData();
    /// @notice Thrown when the supplied or reported token supply is not fixed.
    error InvalidSupply();
    /// @notice Thrown when the token does not use 18 decimals.
    error InvalidTokenDecimals();
    /// @notice Thrown when the configured tick cannot define the launch range.
    error InvalidTickRange();
    /// @notice Thrown when the fee splitter or beneficiary vault is not bound to the same
    ///         PositionManager as this strategy.
    /// @param mismatchedPositionManager The mismatched PositionManager
    error PositionManagerMismatch(address mismatchedPositionManager);
    /// @notice Thrown at deployment when the full supply does not fit in a single position.
    error UnrealizableLaunch();
    /// @notice Thrown at deployment when a launch boundary tick is affordable to fill to its liquidity
    ///         allowance, which would block every later liquidity increase on the launch position.
    /// @param tick The boundary tick that can be filled
    /// @param cost The cheapest amount that fills it
    error SaturableBoundaryTick(int24 tick, uint256 cost);
    /// @notice Thrown when the plan does not resolve to exactly the precomputed launch position.
    error InvalidPositions();
    /// @notice Thrown when the configured fee beneficiary is the zero address or the launcher.
    /// @param feeBeneficiary The invalid fee beneficiary
    error InvalidFeeBeneficiary(address feeBeneficiary);
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
        IBeneficiaryVault _beneficiaryVault,
        int24 _initialTick
    ) {
        // The beneficiary vault is deliberately absent from this check: a zero vault opts the instance
        // out of creator fees, leaving every launch's position unregistered.
        if (
            _launcher == address(0) || address(_positionManager) == address(0) || address(_poolManager) == address(0)
                || address(_feeSplitter) == address(0)
        ) {
            revert ZeroAddress();
        }
        // The splitter collects through its own PositionManager; a mismatch would leave every
        // launch position's fees permanently uncollectable.
        if (_feeSplitter.positionManager() != _positionManager) {
            revert PositionManagerMismatch(address(_feeSplitter.positionManager()));
        }
        // Registration proves custody against the vault's own PositionManager; a mismatch would
        // revert every launch at registration.
        if (address(_beneficiaryVault) != address(0) && _beneficiaryVault.positionManager() != _positionManager) {
            revert PositionManagerMismatch(address(_beneficiaryVault.positionManager()));
        }
        // The tick must be aligned and leave a non-empty range above the launch floor: the launch position
        // spans [MIN_LAUNCH_TICK, initialTick] on the token side of the price. One spacing of headroom above
        // it is required so the band that prices the native door below exists.
        if (
            _initialTick % TICK_SPACING != 0 || _initialTick + TICK_SPACING > TickMath.maxUsableTick(TICK_SPACING)
                || _initialTick <= MIN_LAUNCH_TICK
        ) revert InvalidTickRange();

        launcher = _launcher;
        poolManager = _poolManager;
        positionManager = _positionManager;
        feeSplitter = _feeSplitter;
        beneficiaryVault = _beneficiaryVault;
        initialTick = _initialTick;
        initialSqrtPriceX96 = TickMath.getSqrtPriceAtTick(_initialTick);

        uint128 liquidity = SafeCastLib.toUint128(
            FullMath.mulDiv(
                TOTAL_SUPPLY, FixedPoint96.Q96, initialSqrtPriceX96 - TickMath.getSqrtPriceAtTick(MIN_LAUNCH_TICK)
            )
        );
        // The whole supply must fit in one position. Clamping instead would pass the resolve step in
        // `initializeDistribution` and then silently burn the unplaced remainder of every launch as dust.
        uint128 maxLiquidityPerTick = Pool.tickSpacingToMaxLiquidityPerTick(TICK_SPACING);
        if (liquidity >= maxLiquidityPerTick) revert UnrealizableLaunch();
        positionLiquidity = liquidity;

        // Both of the position's boundary ticks must be unaffordable to fill: v4 raises `liquidityGross` at
        // the lower and the upper tick alike, so filling either one blocks every later increase.
        uint128 headroom = maxLiquidityPerTick - liquidity;
        _requireUnfillableTick(MIN_LAUNCH_TICK, headroom);
        _requireUnfillableTick(_initialTick, headroom);
    }

    /// @notice Reverts unless filling `_tick` to its liquidity allowance is unaffordable in both currencies.
    /// @dev A blocker needs a position with `_tick` as one of its boundaries, and the narrowest such band is
    ///      the cheapest. Which currency funds it follows from where the price sits rather than from the
    ///      blocker's choice — but the price can be moved anywhere outside the launch range for free, so both
    ///      fundings have to be prohibitive. The band below `_tick` is the cheapest token-funded one and the
    ///      band above it the cheapest native-funded one, because the square root of the price grows with the
    ///      tick while its reciprocal shrinks; the mirrored pairings cost strictly more and need no check.
    ///      Amounts round down, since what matters is the least a blocker could get away with.
    /// @param _tick The boundary tick to price
    /// @param _headroom The liquidity left at `_tick` once the launch position occupies its share
    function _requireUnfillableTick(int24 _tick, uint128 _headroom) private pure {
        uint160 sqrtPriceAtTickX96 = TickMath.getSqrtPriceAtTick(_tick);

        uint256 tokenCost = SqrtPriceMath.getAmount1Delta(
            TickMath.getSqrtPriceAtTick(_tick - TICK_SPACING), sqrtPriceAtTickX96, _headroom, false
        );
        if (tokenCost <= TOTAL_SUPPLY) revert SaturableBoundaryTick(_tick, tokenCost);

        uint256 nativeCost = SqrtPriceMath.getAmount0Delta(
            sqrtPriceAtTickX96, TickMath.getSqrtPriceAtTick(_tick + TICK_SPACING), _headroom, false
        );
        if (nativeCost <= MIN_NATIVE_PIN_COST) revert SaturableBoundaryTick(_tick, nativeCost);
    }

    /// @inheritdoc IStrategy
    /// @dev Called by `LiquidityLauncher.distributeToken`, which approves `totalSupply` to this strategy
    ///      first. Pulls exactly `totalSupply` from `msg.sender` (fully consuming the allowance, as the
    ///      launcher's post-call guard requires), then builds the launch pool. `configData` must carry
    ///      the abi-encoded `InstantLaunchConfig` naming the launch's fee beneficiary, registered
    ///      directly with `beneficiaryVault` before the position moves to the splitter. A beneficiary is
    ///      required even when no vault is configured, so `configData` encodes identically against every
    ///      deployment; without a vault it goes unused and the launch carries no creator share. `salt` is
    ///      unused — this singleton strategy uses fixed parameters.
    function initializeDistribution(address token, uint256 totalSupply, bytes calldata configData, bytes32)
        external
        override
        nonReentrant
    {
        // Only accept distributions routed through the configured launcher.
        if (msg.sender != launcher) revert OnlyLauncher();
        if (configData.length == 0) revert InvalidConfigData();
        InstantLaunchConfig memory config = abi.decode(configData, (InstantLaunchConfig));
        _validateFeeBeneficiary(config.feeBeneficiary);
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
                // from the launch floor up to the initial tick.
                offsetLower: MIN_LAUNCH_TICK - initialTick,
                offsetUpper: 0,
                weight: PositionPlanner.MPS,
                overridePositionRecipient: address(0)
            });

            definitions.validate();
            // The position is minted to this strategy and handed to the fee splitter below, which
            // provides permanent custody and permissionless per-pool fee distribution (see FeeSplitter).
            (Position[] memory positions,) = definitions.resolve(
                initialSqrtPriceX96, TICK_SPACING, CurrencyAmounts({amount0: 0, amount1: TOTAL_SUPPLY}), address(this)
            );
            // Exactly the precomputed uncapped position: anything else means part of the supply
            // was left unplaced, and the sub-liquidity-unit rounding dust is burned below.
            if (positions.length != 1 || positions[0].liquidity != positionLiquidity) revert InvalidPositions();

            plan = positions.toPlan(key, ActionConstants.MSG_SENDER);
        }

        IERC20(token).safeTransfer(address(positionManager), TOTAL_SUPPLY);
        uint256 tokenId = positionManager.nextTokenId();
        positionManager.modifyLiquidities(abi.encode(plan.actions, plan.params), block.timestamp);

        // Burn any dust from creating the initial position
        uint256 balanceNow = IERC20(token).balanceOf(address(this));
        if (balanceNow > balanceBefore) IERC20(token).safeTransfer(BURN_ADDRESS, balanceNow - balanceBefore);

        emit DistributionInitialized(address(this), token, totalSupply);
        emit TokenLaunched(poolId, token, address(feeSplitter), key);

        // Optionally register the beneficiary of the position if creator fees are enabled.
        if (address(beneficiaryVault) != address(0)) {
            beneficiaryVault.registerBeneficiary(tokenId, config.feeBeneficiary);
        }
        IERC721(address(positionManager)).transferFrom(address(this), address(feeSplitter), tokenId);
    }

    /// @notice Validates a launch's fee beneficiary.
    /// @dev The beneficiary is freely chosen by the launch configuration; it carries no claim of
    ///      authorship. Zero is rejected, and so is the launcher: fees held by the launcher are
    ///      sweepable by anyone via distributeToken. The beneficiary vault additionally rejects
    ///      itself at registration.
    function _validateFeeBeneficiary(address feeBeneficiary) private view {
        if (feeBeneficiary == address(0) || feeBeneficiary == launcher) {
            revert InvalidFeeBeneficiary(feeBeneficiary);
        }
    }

    /// @notice Pulls exactly `amount` of `token` from `msg.sender`, guarding against callback/FoT tokens
    ///         via a balance-diff check and protecting any pre-existing strategy balance.
    /// @param token The token to pull.
    /// @param amount The amount to pull.
    /// @return balanceBefore The strategy's token balance before the pull.
    function _pull(address token, uint256 amount) private returns (uint256 balanceBefore) {
        balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - balanceBefore;
        if (received != amount) revert TokenAmountMismatch(received, amount);
    }

    /// @notice Accepts ETH so a launch cannot be griefed from leftover ETH in the PositionManager
    receive() external payable {}
}
