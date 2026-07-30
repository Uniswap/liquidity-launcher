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
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {IBeneficiaryVault} from "../interfaces/IBeneficiaryVault.sol";
import {IFeeSplitter} from "../interfaces/IFeeSplitter.sol";
import {PositionPlanner} from "../libraries/PositionPlanner.sol";
import {Plan, Position, CurrencyAmounts, PositionDefinition} from "../types/PositionPlannerTypes.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @notice The launch configuration carried in `configData`.
/// @param feeBeneficiary The recipient of the launch's creator fee share.
struct InstantLaunchConfig {
    address feeBeneficiary;
}

/// @title InstantLaunchStrategy
/// @notice Launches a fixed-supply token directly into a hookless native-ETH v4 pool with a single-sided LP position
/// @custom:security-contact security@uniswap.org
contract InstantLaunchStrategy is IStrategy, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using PositionPlanner for *;

    /// @notice Total token supply required for every launch.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;
    /// @notice Static LP fee of 25 bps
    uint24 public constant LP_FEE = 2_500;
    /// @notice The pool tick spacing
    int24 public constant TICK_SPACING = 60;
    /// @notice The lower tick of every launch position; saturating `maxLiquidityPerTick` from here
    ///         requires more than the total supply.
    int24 public constant MIN_LAUNCH_TICK = -208_980;
    /// @notice The highest permitted initial tick.
    int24 public constant MAX_INITIAL_TICK = 251_340;
    /// @notice Sink for burned tokens (unrecoverable).
    address internal constant BURN_ADDRESS = address(0xdead);

    /// @notice The only caller permitted to initialize distributions; the canonical LiquidityLauncher.
    address public immutable launcher;
    /// @notice The v4 position manager that mints the launch position.
    IPositionManager public immutable positionManager;
    /// @notice The v4 pool manager.
    IPoolManager public immutable poolManager;
    /// @notice The singleton fee splitter that permanently holds every launch position.
    IFeeSplitter public immutable feeSplitter;
    /// @notice The vault that registers each launch's fee beneficiary; zero when this instance
    ///         launches without a creator fee share.
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
    /// @param actual The mismatched PositionManager
    error PositionManagerMismatch(address actual);
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
    /// @param positionRecipient The permanent recipient of the launch LP position.
    /// @param key The initialized pool key.
    event TokenLaunched(PoolId indexed poolId, address indexed token, address indexed positionRecipient, PoolKey key);

    constructor(
        address _launcher,
        IPositionManager _positionManager,
        IPoolManager _poolManager,
        IFeeSplitter _feeSplitter,
        IBeneficiaryVault _beneficiaryVault,
        int24 _initialTick
    ) {
        // A zero beneficiary vault opts the instance out of creator fees.
        if (
            _launcher == address(0) || address(_positionManager) == address(0) || address(_poolManager) == address(0)
                || address(_feeSplitter) == address(0)
        ) {
            revert ZeroAddress();
        }
        if (_feeSplitter.positionManager() != _positionManager) {
            revert PositionManagerMismatch(address(_feeSplitter.positionManager()));
        }
        if (address(_beneficiaryVault) != address(0) && _beneficiaryVault.positionManager() != _positionManager) {
            revert PositionManagerMismatch(address(_beneficiaryVault.positionManager()));
        }
        // The launch position spans [MIN_LAUNCH_TICK, initialTick].
        if (
            _initialTick % TICK_SPACING != 0
                || _initialTick > FixedPointMathLib.min(MAX_INITIAL_TICK, TickMath.maxUsableTick(TICK_SPACING))
                || _initialTick <= MIN_LAUNCH_TICK
        ) revert InvalidTickRange();

        launcher = _launcher;
        poolManager = _poolManager;
        positionManager = _positionManager;
        feeSplitter = _feeSplitter;
        beneficiaryVault = _beneficiaryVault;
        initialTick = _initialTick;
        initialSqrtPriceX96 = TickMath.getSqrtPriceAtTick(_initialTick);

        positionLiquidity = SafeCastLib.toUint128(
            FullMath.mulDiv(
                TOTAL_SUPPLY, FixedPoint96.Q96, initialSqrtPriceX96 - TickMath.getSqrtPriceAtTick(MIN_LAUNCH_TICK)
            )
        );
    }

    /// @inheritdoc IStrategy
    /// @dev Pulls exactly `totalSupply` from `msg.sender`, fully consuming the launcher's allowance.
    ///      `configData` must carry the abi-encoded `InstantLaunchConfig`; a fee beneficiary is required
    ///      even when no vault is configured, and goes unused without one. `salt` is unused.
    function initializeDistribution(address token, uint256 totalSupply, bytes calldata configData, bytes32)
        external
        override
        nonReentrant
    {
        if (msg.sender != launcher) revert OnlyLauncher();
        if (configData.length == 0) revert InvalidConfigData();
        InstantLaunchConfig memory config = abi.decode(configData, (InstantLaunchConfig));
        // Launcher-held fees are sweepable by anyone via `distributeToken`, so the launcher is rejected.
        if (config.feeBeneficiary == address(0) || config.feeBeneficiary == launcher) {
            revert InvalidFeeBeneficiary(config.feeBeneficiary);
        }
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

        // Reverts if the pool is already initialized.
        poolManager.initialize(key, initialSqrtPriceX96);

        Plan memory plan;
        {
            PositionDefinition[] memory definitions = new PositionDefinition[](1);
            definitions[0] = PositionDefinition({
                // Single-sided token range below the opening price: launch floor up to the initial tick.
                offsetLower: MIN_LAUNCH_TICK - initialTick,
                offsetUpper: 0,
                weight: PositionPlanner.MPS,
                overridePositionRecipient: address(0)
            });

            definitions.validate();
            (Position[] memory positions,) = definitions.resolve(
                initialSqrtPriceX96, TICK_SPACING, CurrencyAmounts({amount0: 0, amount1: TOTAL_SUPPLY}), address(this)
            );
            // The plan must resolve to exactly the precomputed position; rounding dust is burned below.
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

        if (address(beneficiaryVault) != address(0)) {
            beneficiaryVault.registerBeneficiary(tokenId, config.feeBeneficiary);
        }
        IERC721(address(positionManager)).transferFrom(address(this), address(feeSplitter), tokenId);
    }

    /// @notice Pulls exactly `amount` of `token` from `msg.sender`; reverts on fee-on-transfer shortfall.
    /// @return balanceBefore The strategy's token balance before the pull.
    function _pull(address token, uint256 amount) private returns (uint256 balanceBefore) {
        balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - balanceBefore;
        if (received != amount) revert TokenAmountMismatch(received, amount);
    }

    /// @notice Receives leftover ETH swept from the PositionManager
    receive() external payable {}
}
