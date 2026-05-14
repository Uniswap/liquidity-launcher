// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "solady/auth/Ownable.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
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
import {IInitializerHook} from "../../interfaces/IInitializerHook.sol";

/// @title LBPStrategy
/// @notice Strategy for distributing tokens to a v4 pool
/// @custom:security-contact security@uniswap.org
contract LBPStrategy is BlockNumberish, Ownable, SelfInitializerMixin, ILBPStrategy {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using MigratorParams for MigratorParameters;

    /// @notice The v4 pool manager
    IPoolManager public immutable poolManager;
    /// @notice The v4 position manager
    IPositionManager public immutable positionManager;
    /// @notice The initializer factory
    IDistributionStrategy public immutable initializerFactory;

    /// @notice The protocol fee controller
    address public protocolFeeController;

    /// @notice The mapping of initializers to their stored migration parameters
    mapping(ILBPInitializer initializer => MigratorParameters) internal _initializers;

    constructor(
        IPositionManager _positionManager,
        IPoolManager _poolManager,
        IDistributionStrategy _initializerFactory,
        address _protocolFeeController,
        address _owner
    ) {
        positionManager = _positionManager;
        poolManager = _poolManager;
        initializerFactory = _initializerFactory;
        _initializeOwner(_owner);
        _setProtocolFeeController(_protocolFeeController);
    }

    /// @inheritdoc IDistributionStrategy
    /// @dev Permissionless by design — the factory controls what initializer is deployed, and all parameters
    /// are validated before storage. Callers cannot overwrite existing initializer registrations.
    /// The initializer factory MUST include the supplied salt in deterministic address calculations; this strategy
    /// derives that salt from the caller-provided salt and MigratorParameters to bind the initializer address to both.
    function initializeDistribution(address token, uint256 totalSupply, bytes calldata configData, bytes32 salt)
        external
        returns (IDistributionContract)
    {
        // Decode the migration parameters (with embedded LP allocation schedule) and auction parameters
        (MigratorParameters memory migrationParams, bytes memory initializerParams) =
            abi.decode(configData, (MigratorParameters, bytes));

        // Validate the configured hook as soon as it is parsed so unsupported hooks are rejected before any deployment.
        if (
            migrationParams.hook != address(0)
                && !ERC165Checker.supportsInterface(migrationParams.hook, type(IInitializerHook).interfaceId)
        ) {
            revert InvalidHook(migrationParams.hook);
        }

        // Validate the migrator parameters (scalar fields, supplyForLP cap, position plan, and LP allocation schedule)
        migrationParams.validate();

        // Deploy the initializer contract via factory.
        // Only the auction supply is passed as the amount — supplyForLP is held as CCA custody tokens (set in initializerParams).
        // LiquidityLauncher transfers the full totalSupply to the CCA, which validates balance >= auctionSupply + custodyTokens.
        bytes32 initializerSalt = keccak256(abi.encode(salt, migrationParams));
        ILBPInitializer initializer = ILBPInitializer(
            address(
                IDistributionStrategy(initializerFactory)
                    .initializeDistribution(token, totalSupply, initializerParams, initializerSalt)
            )
        );

        // Check if the initializer was already registered to ensure parameters are not overwritten.
        // migrationBlock is always non-zero for valid registrations (enforced by _validateInitializer's endBlock check).
        if (_initializers[initializer].migrationBlock != 0) {
            revert InitializerAlreadyCreated(initializer);
        }

        // Validate the initializer parameters are set as expected
        _validateInitializerParams(initializer, migrationParams);

        // Store the parameters
        _initializers[initializer] = migrationParams;

        emit InitializerCreated(initializer, migrationParams);

        return IDistributionContract(address(initializer));
    }

    /// @inheritdoc ILBPStrategy
    /// @dev Permissionless by design — migration is only possible after the migration block, and parameters are
    /// immutably set during initializeDistribution. Anyone can trigger migration
    function migrate(ILBPInitializer initializer) external {
        // Load the stored migration parameters for the initializer
        MigratorParameters memory migrationParams = _initializers[initializer];

        // Ensure the migration block is after the current block. This also reverts if the initializer is unregistered.
        if (_getBlockNumberish() < migrationParams.migrationBlock || migrationParams.migrationBlock == 0) {
            revert MigrationNotAllowed(migrationParams.migrationBlock, _getBlockNumberish());
        }

        // Get the LBP initialization parameters. Trust the initializer to return the correct parameters.
        LBPInitializationParams memory lbpParams = initializer.lbpInitializationParams();

        // Sweep the currency and tokens into the LBP strategy
        initializer.sweepCurrency();
        initializer.sweepUnsoldTokens();

        // Apply the bracket schedule to derive how much currency goes to the LP, then validate.
        // Currency raised above int128.max will not be used to create the v4 pool and instead swept to the funds recipient.
        uint128 currencyAmountForLp = _validateCurrencyAmountForLp(
            _calculateCurrencyAmountForLp(lbpParams.currencyRaised, migrationParams.lpAllocationSchedule)
        );

        // Token and currency addresses are read directly from the initializer rather than from the migration parameters.
        // This requires trusting the initializer to return correct and immutable addresses.
        Currency currency = Currency.wrap(initializer.currency());
        Currency token = Currency.wrap(initializer.token());

        // Derive the sqrt price for the new pool from the auction's final price, accounting for currency ordering.
        uint160 sqrtPriceX96 = _computeSqrtPriceX96(currency, token, lbpParams.initialPriceX96);

        PoolKey memory key = _initializePool(
            currency,
            token,
            sqrtPriceX96,
            migrationParams.poolLPFee,
            migrationParams.poolTickSpacing,
            migrationParams.hook
        );

        // currencyAmountForLp is already <= int128.max from _validateCurrencyAmountForLp;
        // supplyForLP is enforced <= int128.max in _validateMigratorParams.
        (bytes memory plan, uint128 currencyTransferAmount, uint128 tokenTransferAmount) = _createPositionPlan(
            key, currency, sqrtPriceX96, currencyAmountForLp, migrationParams.supplyForLP, migrationParams
        );

        // Transfer the assets to the position manager and execute the position plan. Reentrancy protected by Initializer.sweep
        _transferAssetsAndExecutePlan(currency, token, currencyTransferAmount, tokenTransferAmount, plan);

        // Transfer all leftover currency and tokens to the funds recipient (non LP currency and tokens, unsold & custody tokens and dust)
        uint256 remainingCurrency = currency.balanceOfSelf();
        if (remainingCurrency > 0) {
            currency.transfer(migrationParams.fundsRecipient, remainingCurrency);
            emit CurrencySwept(migrationParams.fundsRecipient, remainingCurrency);
        }
        uint256 remainingToken = token.balanceOfSelf();
        if (remainingToken > 0) {
            token.transfer(migrationParams.fundsRecipient, remainingToken);
            emit TokensSwept(migrationParams.fundsRecipient, remainingToken);
        }

        emit Migrated(initializer, key, sqrtPriceX96);
    }

    /// @inheritdoc ILBPStrategy
    function initializers(ILBPInitializer initializer) external view returns (MigratorParameters memory) {
        return _initializers[initializer];
    }

    /// @inheritdoc ILBPStrategy
    function setProtocolFeeController(address _protocolFeeController) external onlyOwner {
        _setProtocolFeeController(_protocolFeeController);
        emit ProtocolFeeControllerSet(_protocolFeeController);
    }

    /// @notice Sets the protocol fee controller
    /// @param _protocolFeeController The protocol fee controller
    function _setProtocolFeeController(address _protocolFeeController) internal {
        protocolFeeController = _protocolFeeController;
    }

    /// @notice Receive native currency
    receive() external payable {}

    /// @notice Builds the weighted-position plan to be executed against the PositionManager
    /// @dev Returned transfer amounts are the amounts CONSUMED (not remaining), in (currency, token) order
    /// @param key The initialized pool key
    /// @param currency The raised currency
    /// @param sqrtPriceX96 The initialized pool price
    /// @param currencyAmountForLp The currency budget for LP positions
    /// @param tokenAmountForLp The token budget for LP positions
    /// @param mp The stored migration parameters
    /// @return plan The encoded PositionManager plan
    /// @return currencyTransferAmount The currency amount consumed by the plan
    /// @return tokenTransferAmount The token amount consumed by the plan
    function _createPositionPlan(
        PoolKey memory key,
        Currency currency,
        uint160 sqrtPriceX96,
        uint128 currencyAmountForLp,
        uint128 tokenAmountForLp,
        MigratorParameters memory mp
    ) internal virtual returns (bytes memory plan, uint128 currencyTransferAmount, uint128 tokenTransferAmount) {
        bool currencyIsCurrency0 = Currency.unwrap(key.currency0) == Currency.unwrap(currency);

        Position[] memory positions;
        {
            uint128 amount0In = currencyIsCurrency0 ? currencyAmountForLp : tokenAmountForLp;
            uint128 amount1In = currencyIsCurrency0 ? tokenAmountForLp : currencyAmountForLp;
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

        // Initialize the pool with the returned initial price
        // Will revert if:
        //      - Pool is already initialized
        //      - Initial price is not set (sqrtPriceX96 = 0)
        poolManager.initialize(key, initialSqrtPriceX96);

        return key;
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
        // Ensure the funds recipient is indeed this contract
        if (initializer.fundsRecipient() != address(this) || initializer.tokensRecipient() != address(this)) {
            revert InvalidRecipient(address(this));
        }
        // Ensure the migration block is actually after the end block to ensure a successful migration
        if (initializer.endBlock() >= migrationParams.migrationBlock) {
            revert InvalidEndBlock(initializer.endBlock(), migrationParams.migrationBlock);
        }
        // Ensure the CCA's custody tokens match the supplyForLP
        if (initializer.custodyTokensAmount() != migrationParams.supplyForLP) {
            revert InvalidCustodySupply(initializer.custodyTokensAmount(), migrationParams.supplyForLP);
        }
    }

    /// @notice Validates migration currency amount for the LP
    /// @param currencyAmountForLp The currency amount raised for the LP
    function _validateCurrencyAmountForLp(uint256 currencyAmountForLp) private pure returns (uint128) {
        // Cannot create a v4 pool with no currency raised
        if (currencyAmountForLp == 0) {
            revert NoCurrencyRaised();
        }

        // v4's PoolManager._accountDelta uses int128 for currency deltas; amounts above int128.max
        // revert with SafeCastOverflow. Cap here so the excess is swept to fundsRecipient instead.
        if (currencyAmountForLp > uint128(type(int128).max)) {
            return uint128(type(int128).max);
        } else {
            return uint128(currencyAmountForLp);
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
}
