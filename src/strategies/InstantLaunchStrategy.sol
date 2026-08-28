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
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
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

/// @notice The launch configuration carried in `configData`.
/// @param feeBeneficiary The recipient which will receive creator fees if enabled
struct InstantLaunchConfig {
    address feeBeneficiary;
}

/// @notice The pool configuration fixed at deployment. Every tick is expressed with the token as
///         currency1.
/// @param quoteCurrency The currency every launch pairs against
/// @param initialTick The tick at which each pool opens
/// @param minLaunchTick The lower tick of every launch position
/// @param maxInitialTick The highest deployable initial tick
struct LaunchPoolConfig {
    Currency quoteCurrency;
    int24 initialTick;
    int24 minLaunchTick;
    int24 maxInitialTick;
}

/// @title InstantLaunchStrategy
/// @notice Launches a fixed-supply token into a hookless v4 pool against a configured quote currency
///         with a single-sided LP position
/// @dev Every configured tick is expressed with the token as currency1. When a launched token sorts
///      below the quote currency, the pool mirrors: the token becomes currency0 and every tick negates.
/// @custom:security-contact security@uniswap.org
contract InstantLaunchStrategy is IStrategy, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using PositionPlanner for *;

    /// @notice Total token supply required for every launch.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;
    /// @notice Static LP fee of 25 bps
    uint24 public constant LP_FEE = 2_500;
    /// @notice Tick spacing, equal to the LP fee in bps
    int24 public constant TICK_SPACING = 25;
    /// @notice Canonical burn address
    address internal constant BURN_ADDRESS = address(0xdead);

    /// @notice The LiquidityLauncher instance which can initialize distributions.
    address public immutable launcher;
    /// @notice The v4 position manager that mints the launch position.
    IPositionManager public immutable positionManager;
    /// @notice The v4 pool manager.
    IPoolManager public immutable poolManager;
    /// @notice The singleton fee splitter that permanently locks every launch position and
    ///         permissionlessly distributes its fees.
    IFeeSplitter public immutable feeSplitter;
    /// @notice The vault that registers each launch's fee beneficiary and collects their fee share.
    /// @dev Can be the zero address to opt out of creator fees.
    IBeneficiaryVault public immutable beneficiaryVault;
    /// @notice The currency every launch pairs against. The chain's native currency when the wrapped
    ///         address is zero.
    Currency public immutable quoteCurrency;
    /// @notice Lower tick of every launch position. Deployments must choose a floor where saturating
    ///         maxLiquidityPerTick at this tick from either adjacent range costs more than the total
    ///         supply of the token.
    int24 public immutable minLaunchTick;
    /// @notice Highest initial tick. Deployments must choose a cap that keeps saturating
    ///         maxLiquidityPerTick at the launch position's upper tick prohibitively expensive.
    int24 public immutable maxInitialTick;
    /// @notice Tick at which the pool opens when the token is currency1.
    int24 public immutable initialTick;
    /// @notice Initial pool sqrt price when the token is currency1.
    uint160 public immutable initialSqrtPriceX96;
    /// @notice Initial pool sqrt price when the token is currency0 (the mirrored orientation).
    uint160 public immutable mirroredInitialSqrtPriceX96;
    /// @notice Liquidity of the single-sided launch position when the token is currency1.
    uint128 public immutable positionLiquidity;
    /// @notice Liquidity of the single-sided launch position when the token is currency0.
    uint128 public immutable mirroredPositionLiquidity;

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
    /// @notice Thrown when the configured ticks cannot define the launch range.
    error InvalidTickRange();
    /// @notice Thrown when an orientation's launch position liquidity is zero or exceeds the pool's
    ///         per-tick maximum.
    /// @param liquidity The invalid liquidity
    error InvalidPositionLiquidity(uint256 liquidity);
    /// @notice Thrown when the launched token is the quote currency.
    error TokenIsQuoteCurrency();
    /// @notice Thrown when the fee splitter or beneficiary vault is not bound to the same
    ///         PositionManager as this strategy.
    /// @param mismatchedPositionManager The mismatched PositionManager
    error PositionManagerMismatch(address mismatchedPositionManager);
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
        LaunchPoolConfig memory _poolConfig
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
            revert PositionManagerMismatch(address(_feeSplitter.positionManager()));
        }
        // Registration proves custody against the vault's own PositionManager; a mismatch would
        // revert every launch at registration.
        if (address(_beneficiaryVault) != address(0) && _beneficiaryVault.positionManager() != _positionManager) {
            revert PositionManagerMismatch(address(_beneficiaryVault.positionManager()));
        }
        // All ticks must be aligned, ordered, and strictly inside the usable range so both
        // orientations define valid, non-empty launch ranges: [minLaunchTick, initialTick] on the
        // token side of the price, or its mirror image.
        if (
            _poolConfig.initialTick % TICK_SPACING != 0 || _poolConfig.minLaunchTick % TICK_SPACING != 0
                || _poolConfig.maxInitialTick % TICK_SPACING != 0 || _poolConfig.initialTick > _poolConfig.maxInitialTick
                || _poolConfig.initialTick <= _poolConfig.minLaunchTick
                || _poolConfig.maxInitialTick >= TickMath.maxUsableTick(TICK_SPACING)
                || _poolConfig.minLaunchTick <= TickMath.minUsableTick(TICK_SPACING)
        ) {
            revert InvalidTickRange();
        }

        launcher = _launcher;
        poolManager = _poolManager;
        positionManager = _positionManager;
        feeSplitter = _feeSplitter;
        // The beneficiary vault is optional. Setting it to the zero address opts out of creator fees for all launches.
        beneficiaryVault = _beneficiaryVault;
        quoteCurrency = _poolConfig.quoteCurrency;
        initialTick = _poolConfig.initialTick;
        minLaunchTick = _poolConfig.minLaunchTick;
        maxInitialTick = _poolConfig.maxInitialTick;
        initialSqrtPriceX96 = TickMath.getSqrtPriceAtTick(_poolConfig.initialTick);
        mirroredInitialSqrtPriceX96 = TickMath.getSqrtPriceAtTick(-_poolConfig.initialTick);

        // Token as currency1: the position spans [minLaunchTick, initialTick], funded entirely in
        // the token as amount1.
        positionLiquidity = SafeCastLib.toUint128(
            FullMath.mulDiv(
                TOTAL_SUPPLY,
                FixedPoint96.Q96,
                initialSqrtPriceX96 - TickMath.getSqrtPriceAtTick(_poolConfig.minLaunchTick)
            )
        );
        // Token as currency0: the position spans [-initialTick, -minLaunchTick], funded entirely in
        // the token as amount0. The operations match PositionPlanner's liquidity math exactly so a
        // mirrored launch resolves to exactly this liquidity.
        uint160 mirroredUpperSqrtPriceX96 = TickMath.getSqrtPriceAtTick(-_poolConfig.minLaunchTick);
        mirroredPositionLiquidity = SafeCastLib.toUint128(
            FullMath.mulDiv(
                TOTAL_SUPPLY,
                FullMath.mulDiv(mirroredInitialSqrtPriceX96, mirroredUpperSqrtPriceX96, FixedPoint96.Q96),
                mirroredUpperSqrtPriceX96 - mirroredInitialSqrtPriceX96
            )
        );

        // A liquidity above the per-tick maximum would be capped during resolution and fail the
        // exact-liquidity check on every launch.
        uint128 maxLiquidityPerTick = Pool.tickSpacingToMaxLiquidityPerTick(TICK_SPACING);
        if (positionLiquidity == 0 || positionLiquidity > maxLiquidityPerTick) {
            revert InvalidPositionLiquidity(positionLiquidity);
        }
        if (mirroredPositionLiquidity == 0 || mirroredPositionLiquidity > maxLiquidityPerTick) {
            revert InvalidPositionLiquidity(mirroredPositionLiquidity);
        }
    }

    /// @inheritdoc IStrategy
    /// @param configData The abi-encoded `InstantLaunchConfig` containing the address to route creator fees to.
    /// @dev If creator fees are not enabled, the configData is not used but must be provided.
    function initializeDistribution(address token, uint256 totalSupply, bytes calldata configData, bytes32)
        external
        override
        nonReentrant
    {
        if (msg.sender != launcher) revert OnlyLauncher();
        if (configData.length == 0) revert InvalidConfigData();
        InstantLaunchConfig memory config = abi.decode(configData, (InstantLaunchConfig));
        _validateFeeBeneficiary(config.feeBeneficiary);
        // Only accept standard tokens
        if (token == Currency.unwrap(quoteCurrency)) revert TokenIsQuoteCurrency();
        if (totalSupply != TOTAL_SUPPLY || IERC20(token).totalSupply() != TOTAL_SUPPLY) revert InvalidSupply();
        if (IERC20Metadata(token).decimals() != 18) revert InvalidTokenDecimals();

        uint256 balanceBefore = _pull(token, totalSupply);

        // Pool currencies sort by address, so the launch orientation depends on how the token sorts
        // against the quote currency.
        bool tokenIsCurrency0 = token < Currency.unwrap(quoteCurrency);

        PoolKey memory key = PoolKey({
            currency0: tokenIsCurrency0 ? Currency.wrap(token) : quoteCurrency,
            currency1: tokenIsCurrency0 ? quoteCurrency : Currency.wrap(token),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });

        // Will revert if the pool is already initialized.
        poolManager.initialize(key, tokenIsCurrency0 ? mirroredInitialSqrtPriceX96 : initialSqrtPriceX96);

        Plan memory plan;
        {
            PositionDefinition[] memory definitions = new PositionDefinition[](1);
            // The single-sided range sits on the token side of the opening price: below it when the
            // token is currency1 (from the launch floor up to the initial tick), above it when the
            // token is currency0 (the mirrored range).
            definitions[0] = tokenIsCurrency0
                ? PositionDefinition({
                    offsetLower: 0,
                    offsetUpper: initialTick - minLaunchTick,
                    weight: PositionPlanner.MPS,
                    overridePositionRecipient: address(0)
                })
                : PositionDefinition({
                    offsetLower: minLaunchTick - initialTick,
                    offsetUpper: 0,
                    weight: PositionPlanner.MPS,
                    overridePositionRecipient: address(0)
                });

            definitions.validate();
            // The position is minted to this strategy and transferred to the fee splitter below
            (Position[] memory positions,) = definitions.resolve(
                tokenIsCurrency0 ? mirroredInitialSqrtPriceX96 : initialSqrtPriceX96,
                TICK_SPACING,
                tokenIsCurrency0
                    ? CurrencyAmounts({amount0: TOTAL_SUPPLY, amount1: 0})
                    : CurrencyAmounts({amount0: 0, amount1: TOTAL_SUPPLY}),
                address(this)
            );
            // Require exact liquidity to be added
            uint128 expectedLiquidity = tokenIsCurrency0 ? mirroredPositionLiquidity : positionLiquidity;
            if (positions.length != 1 || positions[0].liquidity != expectedLiquidity) revert InvalidPositions();
            // Encode the position into a plan
            plan = positions.toPlan(key, ActionConstants.MSG_SENDER);
        }

        IERC20(token).safeTransfer(address(positionManager), TOTAL_SUPPLY);
        // Cache the next tokenId which will be minted
        uint256 tokenId = positionManager.nextTokenId();
        positionManager.modifyLiquidities(abi.encode(plan.actions, plan.params), block.timestamp);

        // Burn any dust leftover from creating the initial position
        uint256 balanceNow = IERC20(token).balanceOf(address(this));
        if (balanceNow > balanceBefore) IERC20(token).safeTransfer(BURN_ADDRESS, balanceNow - balanceBefore);

        emit DistributionInitialized(address(this), token, totalSupply);
        emit TokenLaunched(key.toId(), token, address(feeSplitter), key);

        // Optionally register the beneficiary of the position if creator fees are enabled.
        if (address(beneficiaryVault) != address(0)) {
            beneficiaryVault.registerBeneficiary(tokenId, config.feeBeneficiary);
        }
        // Transfer the position to the fee splitter
        IERC721(address(positionManager)).transferFrom(address(this), address(feeSplitter), tokenId);
    }

    /// @notice Validates a launch's fee beneficiary.
    /// @dev Cannot be the zero address or the liquidity launcher.
    function _validateFeeBeneficiary(address feeBeneficiary) private view {
        if (feeBeneficiary == address(0) || feeBeneficiary == launcher) {
            revert InvalidFeeBeneficiary(feeBeneficiary);
        }
    }

    /// @notice Pulls exactly `amount` of `token` from `msg.sender`
    /// @dev Reverts if the amount received was less than expected due to fee-on-transfer tokens.
    /// @param token The token to pull.
    /// @param amount The amount to pull.
    /// @return balanceBefore The strategy's token balance before the pull.
    function _pull(address token, uint256 amount) private returns (uint256 balanceBefore) {
        balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - balanceBefore;
        if (received != amount) revert TokenAmountMismatch(received, amount);
    }

    /// @notice Accept ETH
    receive() external payable {}
}
