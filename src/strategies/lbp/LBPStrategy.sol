// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
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
import {
    MigratorParams,
    MigratorParameters,
    LiquidityAllocationBracket,
    PoolParameters
} from "../../libraries/MigratorParams.sol";
import {ILBPStrategy} from "../../interfaces/ILBPStrategy.sol";
import {IDistributorFactory} from "../../interfaces/IDistributorFactory.sol";
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
    IDistributorFactory public immutable initializerFactory;
    /// @notice The mapping of initializers to their stored migration parameters
    mapping(ILBPInitializer initializer => MigratorParameters) internal _initializers;

    /// @notice reservedTokenAmountForLP this strategy holds for each registered initializer. Set when the
    /// initializer is registered; zeroed when its reserves are consumed by the {migrate} waterfall.
    mapping(ILBPInitializer initializer => uint256) public reserves;

    constructor(IPositionManager _positionManager, IPoolManager _poolManager, IDistributorFactory _initializerFactory) {
        positionManager = _positionManager;
        poolManager = _poolManager;
        initializerFactory = _initializerFactory;
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

    /// @notice Initialize an LBP distribution.
    /// @dev Validates the params, deploys the initializer (initializer) via the factory, registers the migration
    ///      parameters, and pulls `totalSupply` tokens from the caller — `auctionSupply` directly into the
    ///      initializer and `reservedTokenAmountForLP` into this strategy. The caller (typically the launcher) must have
    ///      approved this strategy for at least `totalSupply` of `token` before calling.
    function initializeDistribution(address token, uint256 totalSupply, bytes calldata configData, bytes32 salt)
        external
        nonReentrant
    {
        // Decode the migration parameters (with embedded LP allocation schedule) and auction parameters
        (MigratorParameters memory migrationParams, bytes memory initializerParams) =
            abi.decode(configData, (MigratorParameters, bytes));

        // Validate the migrator parameters (scalar fields, reservedTokenAmountForLP cap, position plan, and LP allocation schedule)
        migrationParams.validate();
        // Validate the configured hook as soon as it is parsed so unsupported hooks are rejected before any deployment.
        migrationParams.poolParameters.hook.validateHook();

        // Calculate the salt for the initializer by hashing the caller provided salt with the MigratorParams
        bytes32 initializerSalt = keccak256(abi.encode(salt, migrationParams));
        // Deploy the initializer contract via factory with only auction supply (totalSupply - reservedTokenAmountForLP) passed as the amount
        uint256 auctionSupply = totalSupply - migrationParams.reservedTokenAmountForLP;
        ILBPInitializer initializer = ILBPInitializer(
            address(initializerFactory.create(token, auctionSupply, initializerParams, initializerSalt))
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

        // Pull tokens from the caller: auctionSupply directly into the initializer, reservedTokenAmountForLP into self.
        IERC20(token).safeTransferFrom(msg.sender, address(initializer), auctionSupply);
        IERC20(token).safeTransferFrom(msg.sender, address(this), migrationParams.reservedTokenAmountForLP);

        // Set the reserves for the initializer
        reserves[initializer] = migrationParams.reservedTokenAmountForLP;
        initializer.onTokensReceived();

        emit InitializerCreated(initializer, migrationParams);
    }

    /// @inheritdoc ILBPStrategy
    function migrate(ILBPInitializer initializer) external nonReentrant onlyPendingMigrate(initializer) {
        // Load the stored migration parameters for the initializer
        MigratorParameters memory migrationParams = _initializers[initializer];
        uint256 tokenReserves = reserves[initializer];
        reserves[initializer] = 0;
        Currency currency = Currency.wrap(migrationParams.currency);
        uint256 balanceOfBeforeInit = currency.balanceOfSelf();
        try initializer.sweepCurrency() {} catch {}
        uint256 currencyFromInitializer = currency.balanceOfSelf() - balanceOfBeforeInit;
        // Do not revert here on currencyFromInitializer mismatch. Migrations will revert later until release is called.

        try this.tryMigrate(initializer, migrationParams, balanceOfBeforeInit, currencyFromInitializer) {}
        catch {
            try this.tryFallbackMigrate(initializer, migrationParams, balanceOfBeforeInit, currencyFromInitializer) {}
            catch {
                _release(initializer, migrationParams, tokenReserves, currencyFromInitializer);
            }
        }
    }

    /// @notice Tier 1: configured-plan migration on the committed pool key.
    /// @dev Self-call only; the outer {migrate} holds the reentrancy guard. Reverts on any failure;
    ///      the outer {migrate} then falls through to {tryFallbackMigrate}.
    function tryMigrate(
        ILBPInitializer initializer,
        MigratorParameters memory migrationParams,
        uint256 currencyBefore,
        uint256 currencyFromInitializer
    ) external {
        if (msg.sender != address(this)) revert OnlySelfCall();

        (PoolKey memory key, uint160 sqrtPriceX96,,) =
            _executeMigration(initializer, migrationParams, currencyBefore, currencyFromInitializer);
        emit Migrated(initializer, key, sqrtPriceX96);
    }

    /// @notice Tier 2: attempts migration with a single full-range LP on the original pool key.
    /// @dev Self-call only; the outer {migrate} holds the reentrancy guard. This fallback preserves the
    ///      configured hook and pool key from `MigratorParameters`, and only overrides the configured
    ///      position plan with one full-range position. This is not a hook fallback: the configured hook
    ///      intentionally remains part of the pool key. As a result, tier 2 can recover from position-plan
    ///      failures such as {NoLiquidity}, but it does not recover from failures caused by the configured
    ///      hook or by pool initialization for that same key. If this tier reverts, the outer {migrate}
    ///      falls through to {_release}.
    function tryFallbackMigrate(
        ILBPInitializer initializer,
        MigratorParameters memory migrationParams,
        uint256 currencyBefore,
        uint256 currencyFromInitializer
    ) external {
        if (msg.sender != address(this)) revert OnlySelfCall();

        // Override the configured position plan with a single full-range position so we can reuse the
        // tier-1 planner against the strategy-as-hook pool.
        PositionDefinition[] memory defs = new PositionDefinition[](1);
        defs[0] = PositionDefinition({
            offsetLower: TickMath.MIN_TICK, offsetUpper: TickMath.MAX_TICK, weight: PositionPlanner.MPS
        });
        migrationParams.positionDefinitions = abi.encode(defs);

        (PoolKey memory key, uint160 sqrtPriceX96, uint128 currencyTransferAmount, uint128 tokenTransferAmount) =
            _executeMigration(initializer, migrationParams, currencyBefore, currencyFromInitializer);

        emit FallbackMigrated(initializer, key, sqrtPriceX96, currencyTransferAmount, tokenTransferAmount);
    }

    /// @notice Tier 3: releases held `reservedTokenAmountForLP` and any currency swept during upfront preparation.
    /// @dev Fires only when both {tryMigrate} and {tryFallbackMigrate} reverted. Currency sweeping is attempted
    ///      once in {migrate}; this function only forwards the amount that was actually swept and always releases
    ///      the strategy-held `reservedTokenAmountForLP`.
    function _release(
        ILBPInitializer initializer,
        MigratorParameters memory migrationParams,
        uint256 tokenReserves,
        uint256 currencyFromInitializer
    ) private {
        address recipient = migrationParams.recipient;
        Currency currency = Currency.wrap(migrationParams.currency);

        if (currencyFromInitializer > 0) {
            currency.transfer(recipient, currencyFromInitializer);
            emit CurrencySwept(recipient, currencyFromInitializer);
        }
        if (tokenReserves > 0) {
            IERC20(migrationParams.token).safeTransfer(recipient, tokenReserves);
        }
        emit FundsRecovered(initializer, recipient, tokenReserves);
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
    /// @param mp The stored migration parameters (mp.reservedTokenAmountForLP is used as the token budget for LP positions)
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
            uint128 amount0In = currencyIsCurrency0 ? currencyAmountForLp : mp.reservedTokenAmountForLP;
            uint128 amount1In = currencyIsCurrency0 ? mp.reservedTokenAmountForLP : currencyAmountForLp;
            uint128 remaining0;
            uint128 remaining1;
            (positions, remaining0, remaining1) = PositionPlanner.resolve(
                abi.decode(mp.positionDefinitions, (PositionDefinition[])),
                sqrtPriceX96,
                mp.poolParameters.tickSpacing,
                amount0In,
                amount1In
            );
            if (positions.length == 0) revert NoLiquidity();
            currencyTransferAmount = currencyIsCurrency0 ? amount0In - remaining0 : amount1In - remaining1;
            tokenTransferAmount = currencyIsCurrency0 ? amount1In - remaining1 : amount0In - remaining0;
        }

        Plan memory encodedPlan = PositionPlanner.toPlan(positions, key, mp.positionRecipient);
        plan = abi.encode(encodedPlan.actions, encodedPlan.params);
    }

    /// @notice Executes one migration tier using the hook and position plan in `migrationParams`.
    /// @dev Reverts on any failure so the outer {migrate} waterfall can catch it and advance to the next tier.
    ///      Tier-specific callers may mutate `migrationParams.positionDefinitions` before calling this function,
    ///      but the hook is always read from `migrationParams.hook`. All accounting, pool initialization,
    ///      position minting, and leftover sweeps are shared.
    /// @param initializer The initializer whose prepared migration is being executed
    /// @param migrationParams The migration parameters to use, including the tier's position definitions
    /// @param currencyBefore The strategy's currency balance before the upfront sweep in {migrate}
    /// @param currencyFromInitializer The amount swept from the initializer during upfront preparation
    /// @return key The pool key initialized by this tier
    /// @return sqrtPriceX96 The initial pool price
    /// @return currencyTransferAmount The amount of raised currency consumed by the LP position plan
    /// @return tokenTransferAmount The amount of launched token consumed by the LP position plan
    function _executeMigration(
        ILBPInitializer initializer,
        MigratorParameters memory migrationParams,
        uint256 currencyBefore,
        uint256 currencyFromInitializer
    )
        private
        returns (PoolKey memory key, uint160 sqrtPriceX96, uint128 currencyTransferAmount, uint128 tokenTransferAmount)
    {
        // Use the (token, currency) snapshot captured into MigratorParameters at registration.
        Currency currency = Currency.wrap(migrationParams.currency);
        Currency token = Currency.wrap(migrationParams.token);

        uint256 currencyAmountForLp;
        {
            // Get the lbp params from the initializer. If reverted, the migration will revert and release is called.
            LBPInitializationParams memory lbpParams = initializer.lbpInitializationParams();
            // Amount actually swept must match the currencyRaised the initializer reports.
            if (currencyFromInitializer != lbpParams.currencyRaised) {
                revert CurrencyRaisedMismatch(currencyFromInitializer, lbpParams.currencyRaised);
            }

            // Apply the bracket schedule to derive the LP currency budget.
            // Any excess (above the int128 cap or beyond bracket allocation) is swept to recipient.
            currencyAmountForLp =
                _calculateCurrencyAmountForLp(lbpParams.currencyRaised, migrationParams.lpAllocationSchedule);

            // Derive the sqrt price for the new pool from the auction's final price, accounting for currency ordering.
            sqrtPriceX96 = _computeSqrtPriceX96(currency, token, lbpParams.initialPriceX96);
        }

        key = _initializePool(currency, token, sqrtPriceX96, migrationParams.poolParameters);

        (currencyTransferAmount, tokenTransferAmount) =
            _executePositionPlanAndSweep(key, sqrtPriceX96, currencyAmountForLp, migrationParams, currencyBefore);
    }

    function _executePositionPlanAndSweep(
        PoolKey memory key,
        uint160 sqrtPriceX96,
        uint256 currencyAmountForLp,
        MigratorParameters memory migrationParams,
        uint256 currencyBefore
    ) private returns (uint128 currencyTransferAmount, uint128 tokenTransferAmount) {
        Currency currency = Currency.wrap(migrationParams.currency);
        Currency token = Currency.wrap(migrationParams.token);

        {
            bytes memory plan;
            // v4's PoolManager._accountDelta uses int128 for deltas; cap the LP currency budget before planning.
            // reservedTokenAmountForLP is already enforced <= int128.max in MigratorParams.validate.
            (plan, currencyTransferAmount, tokenTransferAmount) = _createPositionPlan(
                key,
                currency,
                sqrtPriceX96,
                uint128(FixedPointMathLib.min(currencyAmountForLp, uint128(type(int128).max))),
                migrationParams
            );
            _transferAssetsAndExecutePlan(currency, token, currencyTransferAmount, tokenTransferAmount, plan);
        }

        // Sweep this initializer's leftover (non-LP currency and unused reservedTokenAmountForLP) to the leftover recipient.
        // Unsold auction tokens stay in the initializer and are claimed separately by the tokensRecipient.
        uint256 remainingCurrency = currency.balanceOfSelf() - currencyBefore;
        if (remainingCurrency > 0) {
            currency.transfer(migrationParams.recipient, remainingCurrency);
            emit CurrencySwept(migrationParams.recipient, remainingCurrency);
        }
        uint256 remainingToken = migrationParams.reservedTokenAmountForLP - tokenTransferAmount;
        if (remainingToken > 0) {
            token.transfer(migrationParams.recipient, remainingToken);
            emit TokensSwept(migrationParams.recipient, remainingToken);
        }
    }

    /// @notice Initializes the pool with the calculated price
    /// @dev Uses the provided hook directly. Any nonzero hook MUST inherit InitializerHook, and is checked for
    ///      IInitializerHook ERC165 support during initializeDistribution. If hook is address(0), initializes the
    ///      hookless pool unless it already exists, then falls back to this strategy as the hook. address(0) is
    ///      only valid for static-fee pools.
    /// @param currency The currency paired with the launched token
    /// @param token The launched token
    /// @param initialSqrtPriceX96 The sqrt price used to initialize the pool
    /// @param poolParameters The pool parameters to use for the pool
    /// @return key The pool key for the initialized pool
    function _initializePool(
        Currency currency,
        Currency token,
        uint160 initialSqrtPriceX96,
        PoolParameters memory poolParameters
    ) private returns (PoolKey memory key) {
        key = _getPoolKey(currency, token, poolParameters);

        // Initialize the pool with the returned initial price
        // Will revert if:
        //      - Pool is already initialized
        //      - Initial price is not set (sqrtPriceX96 = 0)
        poolManager.initialize(key, initialSqrtPriceX96);

        return key;
    }

    /// @notice Returns the pool key used for migration.
    function _getPoolKey(Currency currency, Currency token, PoolParameters memory poolParameters)
        private
        view
        returns (PoolKey memory key)
    {
        IHooks hook = IHooks(poolParameters.hook);
        key = PoolKey({
            currency0: currency < token ? currency : token,
            currency1: currency < token ? token : currency,
            fee: poolParameters.fee,
            tickSpacing: poolParameters.tickSpacing,
            hooks: hook
        });

        if (address(hook) == address(0)) {
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

    /// @notice Receive native currency
    receive() external payable {}
}
