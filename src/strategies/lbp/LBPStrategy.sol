// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BlockNumberish} from "@uniswap/blocknumberish/src/BlockNumberish.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SelfInitializerMixin} from "./SelfInitializerMixin.sol";
import {TokenPricing} from "../../libraries/TokenPricing.sol";
import {PositionPlanner, CurrencyAmounts} from "../../libraries/PositionPlanner.sol";
import {MigratorParams, MigratorParameters, LiquidityAllocationBracket} from "../../libraries/MigratorParams.sol";
import {ILBPStrategy} from "../../interfaces/ILBPStrategy.sol";
import {IDistributorFactory} from "../../interfaces/IDistributorFactory.sol";
import {Plan, Position, PositionDefinition} from "../../types/PositionPlannerTypes.sol";
import {ILBPInitializer, LBPInitializationParams} from "../../interfaces/ILBPInitializer.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

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

    /// @notice The initializer registered to a poolId. Zeroed when the initializer is migrated.
    mapping(PoolId poolId => address initializer) public registeredPoolIds;

    constructor(IPositionManager _positionManager, IPoolManager _poolManager, IDistributorFactory _initializerFactory) {
        positionManager = _positionManager;
        poolManager = _poolManager;
        initializerFactory = _initializerFactory;
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
        // Native only supported for currency, never as token
        if (token == address(0)) revert ZeroAddressToken();

        // Decode the migration parameters (with embedded LP allocation schedule) and auction parameters
        (MigratorParameters memory migrationParams, bytes memory initializerParams) =
            abi.decode(configData, (MigratorParameters, bytes));

        // Validate the migrator parameters (scalar fields, reservedTokenAmountForLP cap, position plan, and LP allocation schedule)
        migrationParams.validate();

        // Validate the hook is not the strategy itself.  The strategy hook is a fallback for hookless pools that fail to initialize.
        if (migrationParams.poolParameters.hook == address(this)) {
            revert HookIsStrategy();
        }

        // Deploy the initializer contract via factory with only auction supply (totalSupply - reservedTokenAmountForLP) passed as the amount
        uint128 reservedTokenAmountForLP = migrationParams.reservedTokenAmountForLP;
        if (reservedTokenAmountForLP >= totalSupply) {
            revert InvalidReservedTokenAmountForLP();
        }
        uint256 auctionSupply = totalSupply - reservedTokenAmountForLP;

        // Calculate the salt for the initializer by hashing the caller provided salt with the MigratorParams
        bytes32 initializerSalt = keccak256(abi.encode(salt, migrationParams));
        ILBPInitializer initializer = ILBPInitializer(
            address(initializerFactory.create(token, auctionSupply, initializerParams, initializerSalt))
        );

        if (address(initializer) == address(0) || _initializers[initializer].migrationBlock != 0) {
            revert InitializerAlreadyCreated(initializer);
        }
        // Validate the initializer parameters are set as expected (recipients, end block
        _validateInitializerParams(initializer, migrationParams);

        if (migrationParams.token != token || initializer.token() != token) {
            revert TokenMismatch(token, migrationParams.token, initializer.token());
        }
        if (migrationParams.currency != initializer.currency()) {
            revert CurrencyMismatch(migrationParams.currency, initializer.currency());
        }

        // Set the migrator params in storage for future use
        _initializers[initializer] = migrationParams;

        // Record balances before token distribution to ensure the expected funds are received. Fee on transfer tokens are not supported.
        {
            uint256 tokenLBPStrategyBefore = Currency.wrap(token).balanceOfSelf();

            // Pull tokens from the caller: auctionSupply directly into the initializer, reservedTokenAmountForLP into self.
            IERC20(token).safeTransferFrom(msg.sender, address(initializer), auctionSupply);
            IERC20(token).safeTransferFrom(msg.sender, address(this), reservedTokenAmountForLP);

            // Compare balances after token distribution to ensure the expected funds are received.
            uint256 tokenLBPStrategyAfter = Currency.wrap(token).balanceOfSelf();
            if (tokenLBPStrategyAfter - tokenLBPStrategyBefore != reservedTokenAmountForLP) {
                revert TokenAmountMismatch(tokenLBPStrategyAfter - tokenLBPStrategyBefore, reservedTokenAmountForLP);
            }
        }

        // Validate the hook, check if the pool is already initialized and register the initializer for the pool id
        {
            PoolId poolId = _createPoolKey(
                    Currency.wrap(migrationParams.currency),
                    Currency.wrap(token),
                    migrationParams.poolParameters.fee,
                    migrationParams.poolParameters.tickSpacing,
                    migrationParams.poolParameters.hook
                ).toId();
            // Validate the hook address and if the pool is already initialized
            migrationParams.poolParameters.hook.validateHook(migrationParams.poolParameters.fee, poolId, poolManager);
            if (registeredPoolIds[poolId] != address(0)) {
                // The pool id is already reserved by another initializer. Re-launch with different pool
                // parameters (fee/tickSpacing) or a unique InitializerHook to obtain a distinct pool id.
                revert PoolIdOccupied(poolId, registeredPoolIds[poolId]);
            }

            // Register the initializer for the pool id
            registeredPoolIds[poolId] = address(initializer);
        }

        initializer.onTokensReceived();

        emit InitializerCreated(initializer, migrationParams);
    }

    /// @notice Migrate the funds from the initializer and the reserve tokens to a v4 pool
    /// @dev Reverts SHOULD be avoided as much as possible in this function to prevent the liquidity migration from being griefed
    function tryMigrate(ILBPInitializer initializer, MigratorParameters memory migrationParams, PoolKey memory key)
        external
    {
        if (msg.sender != address(this)) revert OnlySelfCall();

        // Use the (token, currency) snapshot captured into MigratorParameters at registration.
        Currency currency = Currency.wrap(migrationParams.currency);
        Currency token = Currency.wrap(migrationParams.token);

        // Snapshot the currency balance of the singleton before calling sweepCurrency on the initializer
        // this represents any existing currency balance in the singleton which is not related to this migration
        uint256 currencyBalanceBefore = currency.balanceOfSelf();
        initializer.sweepCurrency();

        uint160 sqrtPriceX96;
        uint256 currencyAmountForLp;
        {
            // Retrieves the LBP initialization parameters from the initializer. Must revert if the initializer is not graduated.
            LBPInitializationParams memory lbpParams = initializer.lbpInitializationParams();
            // amount actually swept must match the currencyRaised the initializer reports.
            if (currency.balanceOfSelf() - currencyBalanceBefore != lbpParams.currencyRaised) {
                revert CurrencyRaisedMismatch(
                    currency.balanceOfSelf() - currencyBalanceBefore, lbpParams.currencyRaised
                );
            }
            // Apply the bracket schedule to derive the LP currency budget.
            // Any excess (above the int128 cap or beyond bracket allocation) is swept to recipient.
            currencyAmountForLp =
                _calculateCurrencyAmountForLp(lbpParams.currencyRaised, migrationParams.lpAllocationSchedule);
            // Derive the sqrt price for the new pool from the auction's final price, accounting for currency ordering.
            sqrtPriceX96 = _computeSqrtPriceX96(currency, token, lbpParams.initialPriceX96);
        }

        _initializePool(key, sqrtPriceX96);

        // v4's PoolManager._accountDelta uses int128 for deltas; cap the LP currency budget before planning.
        // reservedTokenAmountForLP is already enforced <= int128.max in MigratorParams.validate.
        (bytes memory plan, uint128 currencyTransferAmount, uint128 tokenTransferAmount) = _createPositionPlan(
            key,
            currency,
            sqrtPriceX96,
            uint128(FixedPointMathLib.min(currencyAmountForLp, uint128(type(int128).max))),
            migrationParams
        );

        // Snapshot the token balance of the singleton before calling PositionManager, which includes
        // the token reserves for this migration as well as other unrelated migrations.
        uint256 tokenBalanceBeforePlusReserves = token.balanceOfSelf();

        // Transfer the assets to the position manager and execute the position plan. Reentrancy protected by Initializer.sweep
        _transferAssetsAndExecutePlan(currency, token, currencyTransferAmount, tokenTransferAmount, plan);

        // Sweep this initializer's leftover (non-LP currency and unused reservedTokenAmountForLP) to the recipient.
        // Unsold auction tokens stay in the initializer and are claimed separately by the tokensRecipient.
        // Any leftover dust from the position creation is returned to this contract, and is sent to the recipient.
        _transferCurrency(currency, migrationParams.recipient, currency.balanceOfSelf() - currencyBalanceBefore);
        _transferToken(
            token,
            migrationParams.recipient,
            migrationParams.reservedTokenAmountForLP + token.balanceOfSelf() - tokenBalanceBeforePlusReserves
        );

        emit Migrated(initializer, key, sqrtPriceX96, plan);
    }

    /// @notice Attempts to migrate the initializer and recovers the token reserves if it fails
    function migrate(ILBPInitializer initializer) external nonReentrant {
        MigratorParameters memory migrationParams = _initializers[initializer];

        uint64 migrationBlock = migrationParams.migrationBlock;

        // Ensure the initializer is registered
        if (migrationBlock == 0) revert InitializerNotRegistered(initializer);
        // Ensure the migration is allowed
        if (_getBlockNumberish() < migrationBlock) {
            revert MigrationNotYetAllowed(migrationBlock, _getBlockNumberish());
        }

        Currency currency = Currency.wrap(migrationParams.currency);
        Currency token = Currency.wrap(migrationParams.token);

        PoolKey memory key = _createPoolKey(
            currency,
            token,
            migrationParams.poolParameters.fee,
            migrationParams.poolParameters.tickSpacing,
            migrationParams.poolParameters.hook
        );

        {
            PoolId poolId = key.toId();

            // Ensure the pool id is still registered, to prevent replay attacks
            if (registeredPoolIds[poolId] != address(initializer)) revert InitializerNotRegistered(initializer);

            // Zero out the initializer for the pool id for replay protection
            registeredPoolIds[poolId] = address(0);

            // If no hook is provided, check availability of the hookless pool
            if (migrationParams.poolParameters.hook == address(0)) {
                // See if the hookless pool is already initialized.
                (uint160 existingSqrtPriceX96,,,) = poolManager.getSlot0(poolId);
                if (existingSqrtPriceX96 != 0) {
                    // If the hookless pool exists, fall back to the strategy hook to ensure the pool is initialized.
                    key.hooks = IHooks(address(this));
                    migrationParams.poolParameters.hook = address(this);
                    // NOT updating the pool id, since its not used after this point
                }
            }
        }

        try this.tryMigrate(initializer, migrationParams, key) {}
        catch (bytes memory reason) {
            address recipient = migrationParams.recipient;
            uint256 tokenReserves = migrationParams.reservedTokenAmountForLP;

            // Sweep any raised currency still held on the initializer. The initializer's fundsRecipient is this strategy,
            // so sweepCurrency moves it here; we then forward strictly the delta to leftoverRecipient.
            uint256 currencyBefore = currency.balanceOfSelf();
            // Sweep the currency from the initializer
            initializer.sweepCurrency();
            // Transfer what was received to the recipient
            _transferCurrency(currency, recipient, currency.balanceOfSelf() - currencyBefore);
            // Transfer the token reserves to the recipient
            _transferToken(token, recipient, tokenReserves);

            emit FundsRecovered(initializer, recipient, tokenReserves);
            emit MigrationFailed(initializer, reason);
        }
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
        bool currencyIsCurrency0 = key.currency0 == currency;

        Position[] memory positions;
        CurrencyAmounts memory amounts;
        {
            uint128 amount0In = currencyIsCurrency0 ? currencyAmountForLp : mp.reservedTokenAmountForLP;
            uint128 amount1In = currencyIsCurrency0 ? mp.reservedTokenAmountForLP : currencyAmountForLp;
            // positionRecipient is the default recipient for minted positions: the implicit full-range
            // fallback and any definition that does not set an overridePositionRecipient.
            (positions, amounts) = PositionPlanner.resolve(
                abi.decode(mp.positionDefinitions, (PositionDefinition[])),
                sqrtPriceX96,
                mp.poolParameters.tickSpacing,
                CurrencyAmounts({amount0: amount0In, amount1: amount1In}),
                mp.positionRecipient
            );
            if (positions.length == 0) revert NoPositionsCreated();
            currencyTransferAmount = currencyIsCurrency0
                ? amount0In - SafeCastLib.toUint128(amounts.amount0)
                : amount1In - SafeCastLib.toUint128(amounts.amount1);
            tokenTransferAmount = currencyIsCurrency0
                ? amount1In - SafeCastLib.toUint128(amounts.amount1)
                : amount0In - SafeCastLib.toUint128(amounts.amount0);
        }

        Plan memory encodedPlan = PositionPlanner.toPlan(positions, key, ActionConstants.MSG_SENDER);
        plan = abi.encode(encodedPlan.actions, encodedPlan.params);
    }

    /// @notice Initializes the pool with the calculated price
    /// @dev Initializes exactly the provided key; the hookless→strategy-hook fallback is resolved by the caller
    ///      (`migrate`) before this is called. Reverts if the pool is already initialized.
    /// @param key The pool key for the initialized pool
    /// @param initialSqrtPriceX96 The sqrt price used to initialize the pool
    function _initializePool(PoolKey memory key, uint160 initialSqrtPriceX96) private {
        // Initialize the pool with the returned initial price
        // Will revert if:
        //      - Pool is already initialized
        //      - Initial price is not set (sqrtPriceX96 = 0)
        poolManager.initialize(key, initialSqrtPriceX96);
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
        } else {
            // Both are ERC20 tokens (token can never be native, only currency can be native)
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

    /// @notice Low level function to transfer currency to a recipient
    /// @dev Native currency is force-sent (via SELFDESTRUCT) so a recipient that rejects ETH cannot brick migration.
    ///      The plan's TAKE_PAIR dust is routed back to this strategy and forwarded through here, so it is covered
    ///      by the same force-send protection.
    function _transferCurrency(Currency currency, address recipient, uint256 amount) private {
        if (amount == 0) return;
        if (currency.isAddressZero()) {
            SafeTransferLib.forceSafeTransferETH(recipient, amount);
        } else {
            currency.transfer(recipient, amount);
        }
        emit CurrencySwept(recipient, amount);
    }

    /// @notice Low level function to transfer tokens to a recipient
    function _transferToken(Currency token, address recipient, uint256 amount) private {
        if (amount == 0) return;
        token.transfer(recipient, amount);
        emit TokensSwept(recipient, amount);
    }

    /// @notice Builds the v4 pool key for a (currency, token) pair, ordering the currencies as required by v4
    function _createPoolKey(Currency currency, Currency token, uint24 lpFee, int24 poolTickSpacing, address hook)
        private
        pure
        returns (PoolKey memory key)
    {
        key = PoolKey({
            currency0: currency < token ? currency : token,
            currency1: currency < token ? token : currency,
            fee: lpFee,
            tickSpacing: poolTickSpacing,
            hooks: IHooks(hook)
        });
        return key;
    }

    /// @notice Receive native currency
    receive() external payable {}
}
