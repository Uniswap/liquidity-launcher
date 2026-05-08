// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BlockNumberish} from "@uniswap/blocknumberish/src/BlockNumberish.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TokenPricing} from "../../libraries/TokenPricing.sol";
import {ILBPStrategy} from "../../interfaces/ILBPStrategy.sol";
import {IDistributionStrategy} from "../../interfaces/IDistributionStrategy.sol";
import {IDistributionContract} from "../../interfaces/IDistributionContract.sol";
import {
    ILBPInitializer,
    LBPInitializationParams,
    ILBP_INITIALIZER_INTERFACE_ID
} from "../../interfaces/ILBPInitializer.sol";
import {LBPStrategyConfiguration} from "./LBPStrategyConfiguration.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {HookProxyLib} from "../../periphery/hooks/HookProxy.sol";

/// @title LBPStrategy
/// @notice Strategy for distributing tokens to a v4 pool
/// @custom:security-contact security@uniswap.org
contract LBPStrategy is BlockNumberish, LBPStrategyConfiguration, ILBPStrategy, IDistributionStrategy {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /// @notice Internal helper struct
    struct MigrationData {
        uint160 sqrtPriceX96;
        uint128 fullRangeTokenAmount;
        uint128 fullRangeCurrencyAmount;
        uint128 leftoverToken;
        uint128 leftoverCurrency;
        uint128 liquidity;
    }

    /// @notice The v4 pool manager
    IPoolManager public immutable poolManager;
    /// @notice The v4 position manager
    IPositionManager public immutable positionManager;
    /// @notice The initializer factory
    IDistributionStrategy public immutable initializerFactory;

    /// @notice The mapping of initializers to their stored migration parameters, used to drive migration
    mapping(ILBPInitializer initializer => MigratorParameters) public initializers;

    constructor(
        IPositionManager _positionManager,
        IPoolManager _poolManager,
        IDistributionStrategy _initializerFactory,
        uint24 _minSplitForLp,
        address _protocolFeeController,
        address _owner
    ) {
        positionManager = _positionManager;
        poolManager = _poolManager;
        initializerFactory = _initializerFactory;
        _initializeOwner(_owner);
        _setMinSplitForLp(_minSplitForLp);
        _setProtocolFeeController(_protocolFeeController);
    }

    /// @inheritdoc IDistributionStrategy
    /// @dev Permissionless by design — the factory controls what initializer is deployed, and all parameters
    /// are validated before storage. Callers cannot overwrite existing initializer registrations.
    function initializeDistribution(
        address token,
        uint256 totalSupply,
        bytes calldata configData,
        bytes32 /*salt*/
    )
        external
        returns (IDistributionContract)
    {
        // Decode the migration and auction parameters
        (MigratorParameters memory migrationParams, bytes memory initializerParams) =
            abi.decode(configData, (MigratorParameters, bytes));

        // Validate the migrator parameters
        _validateMigratorParams(migrationParams);

        // Validate that the salt provided results in a valid hook proxy address
        HookProxyLib.preflight(migrationParams.lpHook, migrationParams.hookProxySalt);

        // Deploy the initializer contract via factory.
        // Only the auction supply is passed as the amount — supplyForLP is held as CCA custody tokens (set in initializerParams).
        // LiquidityLauncher transfers the full totalSupply to the CCA, which validates balance >= auctionSupply + custodyTokens.
        ILBPInitializer initializer = ILBPInitializer(
            address(
                IDistributionStrategy(initializerFactory)
                    .initializeDistribution(token, totalSupply, initializerParams, bytes32(0))
            )
        );

        // Check if the initializer was already registered to ensure parameters are not overwritten.
        // migrationBlock is always non-zero for valid registrations (enforced by _validateInitializer's endBlock check).
        if (initializers[initializer].migrationBlock != 0) {
            revert InitializerAlreadyCreated(initializer);
        }

        // Validate the initializer parameters are set as expected
        _validateInitializer(initializer, migrationParams);

        // Store the parameters for the initializer to validate migration parameters during migration
        initializers[initializer] = migrationParams;

        emit InitializerCreated(initializer, migrationParams);

        return IDistributionContract(address(initializer));
    }

    /// @notice Migrates the raised funds and tokens to a v4 pool and sweep the raised funds, unsold and custody tokens to the fundsRecipient
    /// @dev Permissionless by design — migration is only possible after the migration block, and parameters are
    /// immutably set during initializeDistribution. Anyone can trigger migration
    function migrate(ILBPInitializer initializer) external {
        // Load the migration parameters that were stored when the initializer was registered
        MigratorParameters memory migrationParams = initializers[initializer];

        // Ensure the migration block is after the current block. This also reverts if the initializer is unregistered.
        if (_getBlockNumberish() < migrationParams.migrationBlock || migrationParams.migrationBlock == 0) {
            revert MigrationNotAllowed(migrationParams.migrationBlock, _getBlockNumberish());
        }

        // Get the LBP initialization parameters. Trust the initializer to return the correct parameters.
        LBPInitializationParams memory lbpParams = initializer.lbpInitializationParams();

        // Sweep the currency and tokens into the LBP strategy
        initializer.sweepCurrency();
        initializer.sweepUnsoldTokens();

        uint256 currencyAmountForLp =
            _calculateCurrencyAmountForLp(lbpParams.currencyRaised, migrationParams.currencySplitForLP);

        // Ensure the currency amount for the LP is in a valid range to create a v4 pool.
        // Currency raised above uint128.max will not be used to create the v4 pool and instead swept to the funds recipient.
        currencyAmountForLp = _validateCurrencyAmountForLp(currencyAmountForLp);

        // Token and currency addresses are read directly from the initializer rather than from the migration parameters.
        // This requires trusting the initializer to return correct and immutable addresses.
        Currency currency = Currency.wrap(initializer.currency());
        Currency token = Currency.wrap(initializer.token());

        // Prepare the migration data
        MigrationData memory data = _prepareMigrationData(
            currency,
            token,
            uint128(currencyAmountForLp), // Ensured to be less than or equal to type(uint128).max in _validateCurrencyAmountForLp
            migrationParams.supplyForLP,
            lbpParams.initialPriceX96,
            migrationParams.poolTickSpacing
        );

        PoolKey memory key = _initializePool(
            data,
            currency,
            token,
            migrationParams.poolLPFee,
            migrationParams.poolTickSpacing,
            migrationParams.lpHook,
            migrationParams.hookProxySalt
        );

        (bytes memory plan, uint128 currencyTransferAmount, uint128 tokenTransferAmount) = _createPositionPlan(data);

        // Transfer the assets to the position manager and execute the position plan. Reentrancy protected by Initializer.sweep
        _transferAssetsAndExecutePlan(currency, token, currencyTransferAmount, tokenTransferAmount, plan);

        // TODO: Implement fallback full range position plan into _transferAssetsAndExecutePlan if modify liquidities reverts

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

        emit Migrated(initializer, key, data.sqrtPriceX96);
    }

    /// @notice Receive native currency
    receive() external payable {}

    /// @notice Creates the position plan based on migration data
    /// @param _data Migration data with all necessary parameters
    /// @return plan The encoded position plan
    function _createPositionPlan(MigrationData memory _data)
        internal
        virtual
        returns (bytes memory plan, uint128 currencyTransferAmount, uint128 tokenTransferAmount)
    {
        // TODO: Implement the position plan creation via the PositionPlanner library
    }

    /// @notice Initializes the pool with the calculated price
    /// @dev If lpHook only has the beforeInitialize flag (frontrunning protection only), attempts to create a hookless
    ///      pool first for better aggregator compatibility. Falls back to the hooked pool if the hookless pool is already
    ///      initialized. If lpHook has other flags (e.g. governance/timelock), it is always used directly.
    /// @param _data Migration data containing the sqrt price
    /// @return key The pool key for the initialized pool
    function _initializePool(
        MigrationData memory _data,
        Currency currency,
        Currency token,
        uint24 poolLPFee,
        int24 poolTickSpacing,
        address lpHook,
        bytes32 hookProxySalt
    ) private returns (PoolKey memory key) {
        key = PoolKey({
            currency0: _currency0(currency, token),
            currency1: _currency1(currency, token),
            fee: poolLPFee,
            tickSpacing: poolTickSpacing,
            hooks: IHooks(lpHook)
        });

        (uint160 existingSqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        // If the pool already exists, wrap the lpHook in a hook proxy and deploy with a new key
        if (existingSqrtPriceX96 != 0) {
            key.hooks = IHooks(HookProxyLib.deploy(lpHook, hookProxySalt));
        }

        // Initialize the pool with the returned initial price
        // Will revert if:
        //      - Pool is already initialized
        //      - Initial price is not set (sqrtPriceX96 = 0)
        poolManager.initialize(key, _data.sqrtPriceX96);

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

    /// @notice Validates the migrator parameters and reverts if any are invalid. Continues if all are valid
    /// @param _migratorParams The migrator parameters that will be used to create the v4 pool and position
    function _validateMigratorParams(MigratorParameters memory _migratorParams) private view {
        // max currency amount for LP cannot be zero, smaller than the min split for LP or bigger than 100%
        if (
            _migratorParams.currencySplitForLP == 0 || _migratorParams.currencySplitForLP < minSplitForLp
                || _migratorParams.currencySplitForLP > LBPStrategyConfiguration.MAX_SPLIT_FOR_LP
        ) {
            revert InvalidCurrencySplitForLP(
                _migratorParams.currencySplitForLP, minSplitForLp, LBPStrategyConfiguration.MAX_SPLIT_FOR_LP
            );
        }
        // tick spacing validation (cannot be greater than the v4 max tick spacing or less than the v4 min tick spacing)
        if (
            _migratorParams.poolTickSpacing > TickMath.MAX_TICK_SPACING
                || _migratorParams.poolTickSpacing < TickMath.MIN_TICK_SPACING
        ) {
            revert InvalidTickSpacing(
                _migratorParams.poolTickSpacing, TickMath.MIN_TICK_SPACING, TickMath.MAX_TICK_SPACING
            );
        }
        // fee validation (cannot be greater than the v4 max fee)
        if (_migratorParams.poolLPFee > LPFeeLibrary.MAX_LP_FEE) {
            revert InvalidFee(_migratorParams.poolLPFee, LPFeeLibrary.MAX_LP_FEE);
        }
        // position recipient validation (cannot be zero address, address(1), or address(2) which are reserved addresses on the position manager)
        if (
            _migratorParams.lpPositionRecipient == address(0)
                || _migratorParams.lpPositionRecipient == ActionConstants.MSG_SENDER
                || _migratorParams.lpPositionRecipient == ActionConstants.ADDRESS_THIS
        ) {
            revert InvalidPositionRecipient(_migratorParams.lpPositionRecipient);
        }
    }

    /// @notice Validates the auction parameters and reverts if any are invalid. Continues if all are valid
    /// @param initializer The initializer contract
    /// @param migrationParams The migrator parameters that will be used to create the v4 pool and position
    function _validateInitializer(ILBPInitializer initializer, MigratorParameters memory migrationParams) private view {
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

        // Cannot create a v4 pool with more than type(uint128).max currency amount
        if (currencyAmountForLp > type(uint128).max) {
            // If the currency amount for the LP is greater than type(uint128).max, cap to uint128.max sweep the rest to the funds recipient
            return type(uint128).max;
        } else {
            return uint128(currencyAmountForLp);
        }
    }

    /// @notice Prepares all migration data including prices, amounts, and liquidity calculations
    /// @param currencyAmountForLp The total currency amount for the LP
    /// @param initialPriceX96 The initial price of the pool
    /// @return data MigrationData struct containing all calculated values
    function _prepareMigrationData(
        Currency currency,
        Currency token,
        uint128 currencyAmountForLp,
        uint128 tokenAmountForLp,
        uint256 initialPriceX96,
        int24 poolTickSpacing
    ) private pure returns (MigrationData memory) {
        bool currencyIsCurrency0 = _currencyIsCurrency0(currency, token);

        uint256 priceX192 = TokenPricing.convertToPriceX192(initialPriceX96, currencyIsCurrency0);
        uint160 sqrtPriceX96 = TokenPricing.convertToSqrtPriceX96(priceX192);

        (uint128 fullRangeTokenAmount, uint128 fullRangeCurrencyAmount) =
            TokenPricing.calculateAmounts(priceX192, currencyAmountForLp, currencyIsCurrency0, tokenAmountForLp);

        uint128 leftoverCurrency = currencyAmountForLp - fullRangeCurrencyAmount;
        uint128 leftoverToken = tokenAmountForLp - fullRangeTokenAmount;

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(poolTickSpacing)),
            TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(poolTickSpacing)),
            currencyIsCurrency0 ? fullRangeCurrencyAmount : fullRangeTokenAmount,
            currencyIsCurrency0 ? fullRangeTokenAmount : fullRangeCurrencyAmount
        );

        return MigrationData({
            sqrtPriceX96: sqrtPriceX96,
            fullRangeTokenAmount: fullRangeTokenAmount,
            fullRangeCurrencyAmount: fullRangeCurrencyAmount,
            leftoverCurrency: leftoverCurrency,
            leftoverToken: leftoverToken,
            liquidity: liquidity
        });
    }

    function _calculateCurrencyAmountForLp(uint256 currencyAmount, uint24 currencySplitForLP)
        private
        pure
        returns (uint256 currencyAmountForLp)
    {
        currencyAmountForLp =
            FullMath.mulDiv(currencyAmount, currencySplitForLP, LBPStrategyConfiguration.MAX_SPLIT_FOR_LP);
    }

    function _currencyIsCurrency0(Currency currency, Currency token) private pure returns (bool currencyIsCurrency0) {
        assembly ("memory-safe") {
            currencyIsCurrency0 := lt(currency, token)
        }
    }

    function _currency0(Currency currency, Currency token) private pure returns (Currency) {
        return (_currencyIsCurrency0(currency, token) ? currency : token);
    }

    function _currency1(Currency currency, Currency token) private pure returns (Currency) {
        return (_currencyIsCurrency0(currency, token) ? token : currency);
    }
}
