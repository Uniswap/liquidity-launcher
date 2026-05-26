// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BlockNumberish} from "@uniswap/blocknumberish/src/BlockNumberish.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SelfInitializerMixin} from "./SelfInitializerMixin.sol";
import {TokenPricing} from "../../libraries/TokenPricing.sol";
import {PositionPlanner} from "../../libraries/PositionPlanner.sol";
import {MigratorParams, MigratorParameters, LiquidityAllocationBracket} from "../../libraries/MigratorParams.sol";
import {ILBPStrategy} from "../../interfaces/ILBPStrategy.sol";
import {IDistributionStrategy} from "../../interfaces/IDistributionStrategy.sol";
import {IDistributionContract} from "../../interfaces/IDistributionContract.sol";
import {Plan, Position, PositionDefinition} from "../../types/PositionPlannerTypes.sol";
import {
    ILBPInitializer,
    LBPInitializationParams,
    ILBP_INITIALIZER_INTERFACE_ID
} from "../../interfaces/ILBPInitializer.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";

/// @title LBPStrategy
/// @notice Strategy for distributing tokens to a v4 pool
/// @custom:security-contact security@uniswap.org
contract LBPStrategy is BlockNumberish, SelfInitializerMixin, ILBPStrategy, ReentrancyGuardTransient {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using MigratorParams for *;
    using SafeERC20 for IERC20;

    /// @notice The v4 pool manager
    IPoolManager public immutable poolManager;
    /// @notice The v4 position manager
    IPositionManager public immutable positionManager;
    /// @notice The initializer factory
    IDistributionStrategy public immutable initializerFactory;
    /// @notice Forward-compat: previously gated a delayed recovery entrypoint that has since been folded into
    /// the {migrate} waterfall. Retained in the constructor signature so deploy scripts and stacked PRs don't
    /// break; not read by current logic.
    uint256 public immutable recoveryDelayBlocks;

    uint256 private constant Q96 = 1 << 96;
    uint256 private constant Q192 = 1 << 192;

    /// @notice The mapping of initializers to their stored migration parameters
    mapping(ILBPInitializer initializer => MigratorParameters) internal _initializers;

    /// @notice supplyForLP this strategy holds for each registered initializer. Set when the
    /// initializer is registered; zeroed when its reserves are consumed by the {migrate} waterfall.
    mapping(ILBPInitializer initializer => uint256) public reserves;

    struct FallbackAssets {
        Currency currency;
        Currency token;
        uint256 currencyAmount;
        uint256 tokenAmount;
    }

    struct FallbackPositionPlanParams {
        PoolKey key;
        Currency currency;
        uint160 sqrtPriceX96;
        uint128 currencyAmountForLp;
        uint128 tokenAmountForLp;
        address lpPositionRecipient;
    }

    constructor(
        IPositionManager _positionManager,
        IPoolManager _poolManager,
        IDistributionStrategy _initializerFactory,
        uint256 _recoveryDelayBlocks
    ) {
        positionManager = _positionManager;
        poolManager = _poolManager;
        initializerFactory = _initializerFactory;
        recoveryDelayBlocks = _recoveryDelayBlocks;
    }

    /// @notice Modifier requiring the initializer to be in a pending migration state
    /// @dev An initializer is pending migration if it is registered and has a non zero reserve amount
    modifier onlyPendingMigrate(ILBPInitializer initializer) {
        MigratorParameters memory migrationParams = _initializers[initializer];
        if (migrationParams.migrationBlock == 0) revert InitializerNotRegistered(initializer);
        if (reserves[initializer] == 0) revert InsufficientReserves(initializer);
        if (_getBlockNumberish() < migrationParams.migrationBlock) {
            revert MigrationNotYetAllowed(migrationParams.migrationBlock, _getBlockNumberish());
        }
        _;
    }

    /// @inheritdoc IDistributionStrategy
    /// @dev Validates the params, deploys the initializer (initializer) via the factory, registers the migration
    ///      parameters, and pulls `totalSupply` tokens from the caller — `auctionSupply` directly into the
    ///      initializer and `supplyForLP` into this strategy. The caller (typically the launcher) must have
    ///      approved this strategy for at least `totalSupply` of `token` before calling. Returns this
    ///      strategy as the distribution contract.
    function initializeDistribution(address token, uint256 totalSupply, bytes calldata configData, bytes32 salt)
        external
        returns (IDistributionContract)
    {
        // Decode the migration parameters (with embedded LP allocation schedule) and auction parameters
        (MigratorParameters memory migrationParams, bytes memory initializerParams) =
            abi.decode(configData, (MigratorParameters, bytes));

        // Validate the migrator parameters (scalar fields, supplyForLP cap, position plan, and LP allocation schedule)
        migrationParams.validate();
        // Validate the configured hook as soon as it is parsed so unsupported hooks are rejected before any deployment.
        migrationParams.hook.validateHook();

        // Calculate the salt for the initializer by hashing the caller provided salt with the MigratorParams
        bytes32 initializerSalt = keccak256(abi.encode(salt, migrationParams));
        // Deploy the initializer contract via factory with only auction supply (totalSupply - supplyForLP) passed as the amount
        uint256 auctionSupply = totalSupply - migrationParams.supplyForLP;
        ILBPInitializer initializer = ILBPInitializer(
            address(
                IDistributionStrategy(initializerFactory)
                    .initializeDistribution(token, auctionSupply, initializerParams, initializerSalt)
            )
        );

        if (_initializers[initializer].migrationBlock != 0) revert InitializerAlreadyCreated(initializer);
        // Validate the initializer parameters are set as expected
        _validateInitializerParams(initializer, migrationParams);

        if (migrationParams.token != token || initializer.token() != token) {
            revert TokenMismatch(token, migrationParams.token, initializer.token());
        }
        if (migrationParams.currency != initializer.currency()) {
            revert CurrencyMismatch(migrationParams.currency, initializer.currency());
        }

        // Set the migrator params in storage for future use
        _initializers[initializer] = migrationParams;

        // Pull tokens from the caller: auctionSupply directly into the initializer, supplyForLP into self.
        IERC20(token).safeTransferFrom(msg.sender, address(initializer), auctionSupply);
        IERC20(token).safeTransferFrom(msg.sender, address(this), migrationParams.supplyForLP);

        // Set the reserves for the initializer
        reserves[initializer] = migrationParams.supplyForLP;
        initializer.onTokensReceived();

        emit InitializerCreated(initializer, migrationParams);
        return IDistributionContract(address(this));
    }

    /// @notice Migrate the funds from the initializer and the reserve tokens to a v4 pool
    /// @dev Reverts SHOULD be avoided as much as possible in this function to prevent the liquidity migration from being griefed
    function tryMigrate(ILBPInitializer initializer) external {
        if (msg.sender != address(this)) revert OnlySelfCall();

        // Load the stored migration parameters for the initializer
        MigratorParameters memory migrationParams = _initializers[initializer];

        // Zero out the reserves
        reserves[initializer] = 0;

        // Use the (token, currency) snapshot captured into MigratorParameters at registration.
        Currency currency = Currency.wrap(migrationParams.currency);
        Currency token = Currency.wrap(migrationParams.token);

        uint256 currencyBefore = currency.balanceOfSelf();
        initializer.sweepCurrency();

        uint160 sqrtPriceX96;
        uint256 currencyAmountForLp;
        {
            LBPInitializationParams memory lbpParams = initializer.lbpInitializationParams();
            // amount actually swept must match the currencyRaised the initializer reports.
            uint256 currencyFromInitializer = currency.balanceOfSelf() - currencyBefore;
            if (currencyFromInitializer != lbpParams.currencyRaised) {
                revert CurrencyRaisedMismatch(currencyFromInitializer, lbpParams.currencyRaised);
            }
            // Apply the bracket schedule to derive the LP currency budget.
            // Any excess (above the int128 cap or beyond bracket allocation) is swept to leftoverRecipient.
            currencyAmountForLp =
                _calculateCurrencyAmountForLp(lbpParams.currencyRaised, migrationParams.lpAllocationSchedule);
            // Derive the sqrt price for the new pool from the auction's final price, accounting for currency ordering.
            sqrtPriceX96 = _computeSqrtPriceX96(currency, token, lbpParams.initialPriceX96);
        }

        PoolKey memory key = _initializePool(
            currency,
            token,
            sqrtPriceX96,
            migrationParams.poolLPFee,
            migrationParams.poolTickSpacing,
            migrationParams.hook
        );

        // v4's PoolManager._accountDelta uses int128 for deltas; cap the LP currency budget before planning.
        // supplyForLP is already enforced <= int128.max in MigratorParams.validate.
        (bytes memory plan, uint128 currencyTransferAmount, uint128 tokenTransferAmount) = _createPositionPlan(
            key,
            currency,
            sqrtPriceX96,
            uint128(FixedPointMathLib.min(currencyAmountForLp, uint128(type(int128).max))),
            migrationParams
        );

        // Transfer the assets to the position manager and execute the position plan. Reentrancy protected by Initializer.sweep
        _transferAssetsAndExecutePlan(currency, token, currencyTransferAmount, tokenTransferAmount, plan);

        // Sweep this initializer's leftover (non-LP currency and unused supplyForLP) to the leftover recipient.
        // Unsold auction tokens stay in the initializer and are claimed separately by the tokensRecipient.
        uint256 remainingCurrency = currency.balanceOfSelf() - currencyBefore;
        if (remainingCurrency > 0) {
            currency.transfer(migrationParams.leftoverRecipient, remainingCurrency);
            emit CurrencySwept(migrationParams.leftoverRecipient, remainingCurrency);
        }
        uint256 remainingToken = migrationParams.supplyForLP - tokenTransferAmount;
        if (remainingToken > 0) {
            token.transfer(migrationParams.leftoverRecipient, remainingToken);
            emit TokensSwept(migrationParams.leftoverRecipient, remainingToken);
        }

        emit Migrated(initializer, key, sqrtPriceX96);
    }

    /// @inheritdoc ILBPStrategy
    /// @dev Waterfall:
    ///        1. Try the configured-plan migration on the committed pool (`tryMigrate`).
    ///        2. On revert: try a full-range LP on the strategy-as-hook pool (`tryFallbackMigrate`).
    ///        3. On revert: emergency release of supplyForLP and swept currency to leftoverRecipient.
    function migrate(ILBPInitializer initializer) external nonReentrant onlyPendingMigrate(initializer) {
        try this.tryMigrate(initializer) {}
        catch {
            try this.tryFallbackMigrate(initializer) {}
            catch {
                _emergencyRelease(initializer);
            }
        }
    }

    /// @notice Tier-2 fallback: attempt a full-range LP on the strategy-as-hook pool.
    /// @dev Self-call only. Ignores `MigratorParameters.hook` and targets the strategy-as-hook pool key, which is
    ///      gated by `SelfInitializerMixin` so the configured hook (buggy, paused, layout-specific, or adversarial)
    ///      cannot block this path. Tradeoff: fallback LP lands on a different PoolId than `migrate` would have.
    ///      Known structural failure modes (no currency, mismatched raise, invalid price, no resolvable
    ///      liquidity, strategy-hook pool initialization fails, PositionManager reverts) are handled internally
    ///      by releasing held assets to `leftoverRecipient` and emitting {FallbackMigrationReleased}; this
    ///      function only reverts on unexpected failures, in which case the outer `migrate` falls through to
    ///      {_emergencyRelease}.
    function tryFallbackMigrate(ILBPInitializer initializer) external {
        if (msg.sender != address(this)) revert OnlySelfCall();
        MigratorParameters memory mp = _initializers[initializer];

        FallbackAssets memory assets;
        assets.tokenAmount = reserves[initializer];
        reserves[initializer] = 0;

        assets.currency = Currency.wrap(mp.currency);
        assets.token = Currency.wrap(mp.token);
        uint256 currencyBefore = assets.currency.balanceOfSelf();
        initializer.sweepCurrency();

        assets.currencyAmount = assets.currency.balanceOfSelf() - currencyBefore;
        if (assets.currencyAmount == 0) {
            _releaseFallbackAssets(initializer, assets, mp.leftoverRecipient, FallbackReleaseReason.NoCurrency);
            return;
        }

        LBPInitializationParams memory lbpParams = initializer.lbpInitializationParams();
        if (assets.currencyAmount != lbpParams.currencyRaised) {
            _releaseFallbackAssets(initializer, assets, mp.leftoverRecipient, FallbackReleaseReason.CurrencyMismatch);
            return;
        }

        _executeFallbackMigration(initializer, mp, assets, lbpParams.initialPriceX96);
    }

    /// @notice Tier-3 emergency release. Invoked only when {tryFallbackMigrate} itself reverts unexpectedly.
    /// @dev `tryFallbackMigrate`'s state changes are rolled back on revert, so `reserves[initializer]` is back
    ///      at its original `supplyForLP` value and the raised currency is back on the initializer. Try the
    ///      sweep best-effort — if it reverts (e.g., it was the original cause of tier-2's failure), still
    ///      release the strategy-held `supplyForLP` so funds aren't permanently locked.
    function _emergencyRelease(ILBPInitializer initializer) private {
        MigratorParameters memory mp = _initializers[initializer];
        FallbackAssets memory assets;
        assets.currency = Currency.wrap(mp.currency);
        assets.token = Currency.wrap(mp.token);
        assets.tokenAmount = reserves[initializer];
        reserves[initializer] = 0;

        uint256 currencyBefore = assets.currency.balanceOfSelf();
        try initializer.sweepCurrency() {} catch {}
        assets.currencyAmount = assets.currency.balanceOfSelf() - currencyBefore;

        _releaseFallbackAssets(initializer, assets, mp.leftoverRecipient, FallbackReleaseReason.PositionManagerFailed);
    }

    function _executeFallbackMigration(
        ILBPInitializer initializer,
        MigratorParameters memory mp,
        FallbackAssets memory assets,
        uint256 initialPriceX96
    ) private {
        (bool validPrice, uint160 sqrtPriceX96) =
            _tryComputeSqrtPriceX96(assets.currency, assets.token, initialPriceX96);
        if (!validPrice) {
            _releaseFallbackAssets(initializer, assets, mp.leftoverRecipient, FallbackReleaseReason.InvalidPrice);
            return;
        }

        // Strategy-as-hook pool key. `SelfInitializerMixin` ensures only this strategy can initialize it.
        PoolKey memory key = _getPoolKey(assets.currency, assets.token, mp.poolLPFee, mp.poolTickSpacing, address(this));

        (bool canFallbackMigrate, bytes memory plan, uint128 currencyTransferAmount, uint128 tokenTransferAmount) = _createFallbackPositionPlan(
            key,
            assets.currency,
            sqrtPriceX96,
            uint128(FixedPointMathLib.min(assets.currencyAmount, uint128(type(int128).max))),
            uint128(assets.tokenAmount),
            mp.lpPositionRecipient
        );

        if (!canFallbackMigrate) {
            _releaseFallbackAssets(initializer, assets, mp.leftoverRecipient, FallbackReleaseReason.NoLiquidity);
            return;
        }

        try poolManager.initialize(key, sqrtPriceX96) {}
        catch {
            _releaseFallbackAssets(
                initializer, assets, mp.leftoverRecipient, FallbackReleaseReason.PoolInitializationFailed
            );
            return;
        }

        bool success = _tryTransferAssetsAndExecutePlan(
            assets.currency, assets.token, currencyTransferAmount, tokenTransferAmount, plan
        );
        if (!success) {
            _releaseFallbackAssets(
                initializer, assets, mp.leftoverRecipient, FallbackReleaseReason.PositionManagerFailed
            );
            return;
        }

        uint256 remainingCurrency = assets.currencyAmount - currencyTransferAmount;
        if (remainingCurrency > 0) {
            assets.currency.transfer(mp.leftoverRecipient, remainingCurrency);
            emit CurrencySwept(mp.leftoverRecipient, remainingCurrency);
        }

        uint256 remainingToken = assets.tokenAmount - tokenTransferAmount;
        if (remainingToken > 0) {
            assets.token.transfer(mp.leftoverRecipient, remainingToken);
            emit TokensSwept(mp.leftoverRecipient, remainingToken);
        }

        emit FallbackMigrated(initializer, key, sqrtPriceX96, currencyTransferAmount, tokenTransferAmount);
    }

    /// @inheritdoc ILBPStrategy
    function initializers(ILBPInitializer initializer) external view returns (MigratorParameters memory) {
        return _initializers[initializer];
    }

    /// @notice Builds the weighted-position plan to be executed against the PositionManager
    /// @dev Returned transfer amounts are the amounts CONSUMED (not remaining), in (currency, token) order
    /// @param key The initialized pool key
    /// @param currency The raised currency
    /// @param sqrtPriceX96 The initialized pool price
    /// @param currencyAmountForLp The currency budget for LP positions
    /// @param mp The stored migration parameters (mp.supplyForLP is used as the token budget for LP positions)
    /// @return plan The encoded PositionManager plan
    /// @return currencyTransferAmount The currency amount consumed by the plan
    /// @return tokenTransferAmount The token amount consumed by the plan
    function _createPositionPlan(
        PoolKey memory key,
        Currency currency,
        uint160 sqrtPriceX96,
        uint128 currencyAmountForLp,
        MigratorParameters memory mp
    ) internal virtual returns (bytes memory plan, uint128 currencyTransferAmount, uint128 tokenTransferAmount) {
        bool currencyIsCurrency0 = Currency.unwrap(key.currency0) == Currency.unwrap(currency);

        Position[] memory positions;
        {
            uint128 amount0In = currencyIsCurrency0 ? currencyAmountForLp : mp.supplyForLP;
            uint128 amount1In = currencyIsCurrency0 ? mp.supplyForLP : currencyAmountForLp;
            uint128 remaining0;
            uint128 remaining1;
            (positions, remaining0, remaining1) = PositionPlanner.resolve(
                abi.decode(mp.positionDefinitions, (PositionDefinition[])),
                sqrtPriceX96,
                mp.poolTickSpacing,
                amount0In,
                amount1In
            );
            currencyTransferAmount = currencyIsCurrency0 ? amount0In - remaining0 : amount1In - remaining1;
            tokenTransferAmount = currencyIsCurrency0 ? amount1In - remaining1 : amount0In - remaining0;
        }

        Plan memory encodedPlan = PositionPlanner.toPlan(positions, key, mp.lpPositionRecipient);
        plan = abi.encode(encodedPlan.actions, encodedPlan.params);
    }

    /// @notice Builds a single full-range fallback position plan.
    function _createFallbackPositionPlan(
        PoolKey memory key,
        Currency currency,
        uint160 sqrtPriceX96,
        uint128 currencyAmountForLp,
        uint128 tokenAmountForLp,
        address lpPositionRecipient
    )
        internal
        pure
        returns (bool success, bytes memory plan, uint128 currencyTransferAmount, uint128 tokenTransferAmount)
    {
        return _createFallbackPositionPlan(
            FallbackPositionPlanParams({
                key: key,
                currency: currency,
                sqrtPriceX96: sqrtPriceX96,
                currencyAmountForLp: currencyAmountForLp,
                tokenAmountForLp: tokenAmountForLp,
                lpPositionRecipient: lpPositionRecipient
            })
        );
    }

    function _createFallbackPositionPlan(FallbackPositionPlanParams memory params)
        private
        pure
        returns (bool success, bytes memory plan, uint128 currencyTransferAmount, uint128 tokenTransferAmount)
    {
        if (params.currencyAmountForLp == 0 || params.tokenAmountForLp == 0) return (false, bytes(""), 0, 0);

        (bool currencyIsCurrency0, uint128 amount0In, uint128 amount1In) =
            _fallbackInputAmounts(params.key, params.currency, params.currencyAmountForLp, params.tokenAmountForLp);

        (Position[] memory positions, uint128 remaining0, uint128 remaining1) =
            _resolveFullRangeFallbackPosition(params.sqrtPriceX96, params.key.tickSpacing, amount0In, amount1In);

        if (positions.length == 0) return (false, bytes(""), 0, 0);

        currencyTransferAmount = currencyIsCurrency0 ? amount0In - remaining0 : amount1In - remaining1;
        tokenTransferAmount = currencyIsCurrency0 ? amount1In - remaining1 : amount0In - remaining0;
        if (currencyTransferAmount == 0 || tokenTransferAmount == 0) return (false, bytes(""), 0, 0);

        Plan memory encodedPlan = PositionPlanner.toPlan(positions, params.key, params.lpPositionRecipient);
        return (true, abi.encode(encodedPlan.actions, encodedPlan.params), currencyTransferAmount, tokenTransferAmount);
    }

    function _fallbackInputAmounts(
        PoolKey memory key,
        Currency currency,
        uint128 currencyAmountForLp,
        uint128 tokenAmountForLp
    ) private pure returns (bool currencyIsCurrency0, uint128 amount0In, uint128 amount1In) {
        currencyIsCurrency0 = Currency.unwrap(key.currency0) == Currency.unwrap(currency);
        amount0In = currencyIsCurrency0 ? currencyAmountForLp : tokenAmountForLp;
        amount1In = currencyIsCurrency0 ? tokenAmountForLp : currencyAmountForLp;
    }

    function _resolveFullRangeFallbackPosition(
        uint160 sqrtPriceX96,
        int24 tickSpacing,
        uint128 amount0In,
        uint128 amount1In
    ) private pure returns (Position[] memory positions, uint128 remaining0, uint128 remaining1) {
        PositionDefinition[] memory definitions = new PositionDefinition[](1);
        definitions[0] = PositionDefinition({
            offsetLower: TickMath.MIN_TICK, offsetUpper: TickMath.MAX_TICK, weight: PositionPlanner.MPS
        });

        return PositionPlanner.resolve(definitions, sqrtPriceX96, tickSpacing, amount0In, amount1In);
    }

    /// @notice Initializes the pool with the calculated price
    /// @dev Uses the provided hook directly. Any nonzero hook MUST inherit InitializerHook, and is checked for
    ///      IInitializerHook ERC165 support during initializeDistribution. If hook is address(0), initializes the
    ///      hookless pool unless it already exists, then falls back to this strategy as the hook.
    /// @param currency The currency paired with the launched token
    /// @param token The launched token
    /// @param initialSqrtPriceX96 The sqrt price used to initialize the pool
    /// @param poolLPFee The LP fee for the pool
    /// @param poolTickSpacing The tick spacing for the pool
    /// @param hook The hook address for the pool. Any nonzero hook MUST inherit InitializerHook. address(0) targets
    ///        the hookless pool unless it already exists.
    /// @return key The pool key for the initialized pool
    function _initializePool(
        Currency currency,
        Currency token,
        uint160 initialSqrtPriceX96,
        uint24 poolLPFee,
        int24 poolTickSpacing,
        address hook
    ) private returns (PoolKey memory key) {
        key = _getPoolKey(currency, token, poolLPFee, poolTickSpacing, hook);

        // Initialize the pool with the returned initial price
        // Will revert if:
        //      - Pool is already initialized
        //      - Initial price is not set (sqrtPriceX96 = 0)
        poolManager.initialize(key, initialSqrtPriceX96);

        return key;
    }

    /// @notice Returns the pool key used for migration.
    function _getPoolKey(Currency currency, Currency token, uint24 poolLPFee, int24 poolTickSpacing, address hook)
        private
        view
        returns (PoolKey memory key)
    {
        key = PoolKey({
            currency0: currency < token ? currency : token,
            currency1: currency < token ? token : currency,
            fee: poolLPFee,
            tickSpacing: poolTickSpacing,
            hooks: IHooks(hook)
        });

        if (hook == address(0)) {
            // See if the hookless pool is already initialized.
            (uint160 existingSqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
            if (existingSqrtPriceX96 != 0) {
                // If the hookless pool exists, initialize a strategy-hooked pool instead.
                key.hooks = IHooks(address(this));
            }
        }
    }

    /// @notice Transfers assets to position manager and executes the position plan
    /// @param currency The currency to transfer to the position manager
    /// @param token The token to transfer to the position manager
    /// @param currencyTransferAmount The amount of currency to transfer to the position manager
    /// @param tokenTransferAmount The amount of tokens to transfer to the position manager
    /// @param _plan The encoded position plan to execute
    function _transferAssetsAndExecutePlan(
        Currency currency,
        Currency token,
        uint128 currencyTransferAmount,
        uint128 tokenTransferAmount,
        bytes memory _plan
    ) private {
        // Transfer tokens to position manager and execute the position plan via modifyLiquidities
        if (currency.isAddressZero()) {
            // Currency is native
            token.transfer(address(positionManager), tokenTransferAmount);
            positionManager.modifyLiquidities{value: currencyTransferAmount}(_plan, block.timestamp);
        } else if (token.isAddressZero()) {
            // Token is native
            currency.transfer(address(positionManager), currencyTransferAmount);
            positionManager.modifyLiquidities{value: tokenTransferAmount}(_plan, block.timestamp);
        } else {
            // Both are ERC20 tokens
            token.transfer(address(positionManager), tokenTransferAmount);
            currency.transfer(address(positionManager), currencyTransferAmount);
            positionManager.modifyLiquidities(_plan, block.timestamp);
        }
    }

    /// @notice Transfers assets to position manager and executes a position plan, sweeping ERC20s back on failure.
    /// @dev Native currency sent as msg.value is returned automatically when modifyLiquidities reverts.
    function _tryTransferAssetsAndExecutePlan(
        Currency currency,
        Currency token,
        uint128 currencyTransferAmount,
        uint128 tokenTransferAmount,
        bytes memory _plan
    ) private returns (bool success) {
        if (currency.isAddressZero()) {
            token.transfer(address(positionManager), tokenTransferAmount);
            try positionManager.modifyLiquidities{value: currencyTransferAmount}(_plan, block.timestamp) {
                return true;
            } catch {
                _sweepPositionManagerCurrency(token);
                return false;
            }
        } else if (token.isAddressZero()) {
            currency.transfer(address(positionManager), currencyTransferAmount);
            try positionManager.modifyLiquidities{value: tokenTransferAmount}(_plan, block.timestamp) {
                return true;
            } catch {
                _sweepPositionManagerCurrency(currency);
                return false;
            }
        } else {
            token.transfer(address(positionManager), tokenTransferAmount);
            currency.transfer(address(positionManager), currencyTransferAmount);
            try positionManager.modifyLiquidities(_plan, block.timestamp) {
                return true;
            } catch {
                _sweepPositionManagerCurrency(token);
                _sweepPositionManagerCurrency(currency);
                return false;
            }
        }
    }

    /// @notice Sweeps a PositionManager ERC20 balance back to this strategy.
    function _sweepPositionManagerCurrency(Currency currency) private {
        if (currency.isAddressZero()) return;

        bytes memory actions = new bytes(1);
        bytes[] memory params = new bytes[](1);
        actions[0] = bytes1(uint8(Actions.SWEEP));
        params[0] = abi.encode(currency, address(this));

        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);
    }

    /// @notice Releases fallback assets to the leftover recipient.
    function _releaseFallbackAssets(
        ILBPInitializer initializer,
        FallbackAssets memory assets,
        address leftoverRecipient,
        FallbackReleaseReason reason
    ) private {
        if (assets.currencyAmount > 0) {
            assets.currency.transfer(leftoverRecipient, assets.currencyAmount);
        }
        if (assets.tokenAmount > 0) assets.token.transfer(leftoverRecipient, assets.tokenAmount);
        emit FallbackMigrationReleased(
            initializer, leftoverRecipient, assets.currencyAmount, assets.tokenAmount, reason
        );
    }

    /// @notice Validates the auction parameters and reverts if any are invalid. Continues if all are valid
    /// @param initializer The initializer contract
    /// @param migrationParams The migrator parameters that will be used to create the v4 pool and position
    function _validateInitializerParams(ILBPInitializer initializer, MigratorParameters memory migrationParams)
        private
        view
    {
        // The strategy must be the fundsRecipient (it sweeps currency during migration), but must NOT be the
        // tokensRecipient — unsold auction tokens are claimed directly by the configured tokensRecipient via
        // the initializer's sweepUnsoldTokens.
        address fundsRecipient = initializer.fundsRecipient();
        if (fundsRecipient != address(this)) {
            revert InvalidFundsRecipient(fundsRecipient, address(this));
        }
        address tokensRecipient = initializer.tokensRecipient();
        if (tokensRecipient == address(this)) {
            revert InvalidTokensRecipient(tokensRecipient);
        }
        // Ensure the migration block is actually after the end block to ensure a successful migration
        if (initializer.endBlock() >= migrationParams.migrationBlock) {
            revert InvalidEndBlock(initializer.endBlock(), migrationParams.migrationBlock);
        }
    }

    /// @notice Calculates the currency amount allocated to the LP using a piecewise bracket curve
    /// @dev Decodes the abi-encoded schedule and iterates it. Each non-last bracket allocates
    /// min(remaining, bracketSize) at its rate, where bracketSize = next.lowerThreshold − this.lowerThreshold.
    /// The last bracket's rate applies to all remaining currency (extends to infinity).
    /// @param currencyAmount The total currency raised
    /// @param schedule The abi-encoded LiquidityAllocationBracket[] schedule
    /// @return lpAmount The currency amount allocated to the LP
    function _calculateCurrencyAmountForLp(uint256 currencyAmount, bytes memory schedule)
        private
        pure
        returns (uint256 lpAmount)
    {
        LiquidityAllocationBracket[] memory brackets = abi.decode(schedule, (LiquidityAllocationBracket[]));
        uint256 remaining = currencyAmount;
        uint256 count = brackets.length;

        for (uint256 i = 0; i < count; i++) {
            uint256 lowerThreshold = brackets[i].lowerThreshold;
            uint24 rate = brackets[i].rate;

            if (i == count - 1) {
                // Last bracket: its rate applies to all remaining currency
                lpAmount += FullMath.mulDiv(remaining, rate, MigratorParams.MAX_BRACKET_RATE);
                break;
            }

            uint256 nextLower = brackets[i + 1].lowerThreshold;
            uint256 bracketSize = nextLower - lowerThreshold;
            uint256 bracketAmount = remaining > bracketSize ? bracketSize : remaining;
            lpAmount += FullMath.mulDiv(bracketAmount, rate, MigratorParams.MAX_BRACKET_RATE);
            unchecked {
                remaining -= bracketAmount;
            }

            if (remaining == 0) break;
        }
    }

    /// @notice Derives the initial sqrt price for the v4 pool from the auction's final price
    /// @dev Adjusts the raw X96 price for currency ordering before converting to a sqrtPriceX96.
    /// @param currency The raised currency
    /// @param token The launched token
    /// @param initialPriceX96 The auction's final price expressed as currency-per-token (X96 fixed-point)
    /// @return sqrtPriceX96 The initialization price to hand to the pool manager
    function _computeSqrtPriceX96(Currency currency, Currency token, uint256 initialPriceX96)
        private
        pure
        returns (uint160 sqrtPriceX96)
    {
        uint256 priceX192 = TokenPricing.convertToPriceX192(initialPriceX96, currency < token);
        sqrtPriceX96 = TokenPricing.convertToSqrtPriceX96(priceX192);
    }

    /// @notice Non-reverting fallback price conversion.
    function _tryComputeSqrtPriceX96(Currency currency, Currency token, uint256 initialPriceX96)
        private
        pure
        returns (bool success, uint160 sqrtPriceX96)
    {
        if (initialPriceX96 == 0) return (false, 0);

        uint256 priceX192;
        if (currency < token) {
            uint256 invertedPrice = Q192 / initialPriceX96;
            if (invertedPrice >> 160 != 0) return (false, 0);
            priceX192 = FullMath.mulDiv(Q192, Q96, initialPriceX96);
        } else {
            if (initialPriceX96 >> 160 != 0) return (false, 0);
            priceX192 = initialPriceX96 << 96;
        }

        sqrtPriceX96 = uint160(Math.sqrt(priceX192));
        if (sqrtPriceX96 < TickMath.MIN_SQRT_PRICE || sqrtPriceX96 > TickMath.MAX_SQRT_PRICE) {
            return (false, 0);
        }

        return (true, sqrtPriceX96);
    }

    /// @notice Receive native currency
    receive() external payable {}
}
