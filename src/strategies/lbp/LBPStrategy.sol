// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BlockNumberish} from "@uniswap/blocknumberish/src/BlockNumberish.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {Currency} from "continuous-clearing-auction/src/libraries/CurrencyLibrary.sol";
import {AuctionParameters} from "continuous-clearing-auction/src/interfaces/IContinuousClearingAuction.sol";
import {ILBPStrategy} from "../../interfaces/ILBPStrategy.sol";
import {ILBPInitializer} from "../../interfaces/ILBPInitializer.sol";
import {IDistributionStrategy} from "../../interfaces/IDistributionStrategy.sol";
import {IDistributionContract} from "../../interfaces/IDistributionContract.sol";
import {
    ILBPInitializer,
    LBPInitializationParams,
    ILBP_INITIALIZER_INTERFACE_ID
} from "../../interfaces/ILBPInitializer.sol";

/// @title LBPStrategy
/// @notice Strategy for distributing tokens to a v4 pool
/// @custom:security-contact security@uniswap.org
contract LBPStrategy is Ownable, BlockNumberish, ILBPStrategy, IDistributionStrategy {
    struct Settings {
        address protocolFeeController; // the address defining the protocol fee payed on non-LP currency
        uint24 minSplitForLP; // the minimum percentage (in mps) of the total supply of the token that must be sent to an LP
    }

    IPoolManager public immutable poolManager;
    IPositionManager public immutable positionManager;
    IDistributionStrategy public immutable initializerFactory;

    // Owner controlled settings
    Settings public settings;

    /// @notice The mapping of initializers to their identifiers ensuring the validity of provided calldata during migration
    mapping(ILBPInitializer initializer => bytes32 identifier) public initializers;

    constructor(
        IPositionManager _positionManager,
        IPoolManager _poolManager,
        IDistributionStrategy _initializerFactory
    ) {
        positionManager = _positionManager;
        poolManager = _poolManager;
        initializerFactory = _initializerFactory;
        _initializeOwner(msg.sender);
    }

    function setSettings(Settings calldata _settings) external onlyOwner {
        settings = _settings;
        emit SettingsSet(_settings.protocolFeeController, _settings.minSplitForLP);
    }

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
        MigratorParameters calldata migrationParams;
        AuctionParameters calldata auctionParams;
        assembly ("memory-safe") {
            migrationParams := configData.offset // starts with the MigratorParameters struct (non dynamic struct)
            auctionParams := add(configData.offset, 0x100) // 0x100 skips the MigratorParameters struct and points directly at auctionParams.offset
        }

        // Ensure the funds recipient is this contract
        if (auctionParams.fundsRecipient != address(this) || auctionParams.tokensRecipient != address(this)) {
            revert InvalidRecipient(address(this));
        }
        // Ensure the migration block is after the end block to ensure a successful migration
        if (auctionParams.endBlock >= migrationParams.migrationBlock) {
            revert InvalidEndBlock(auctionParams.endBlock, migrationParams.migrationBlock);
        }

        // Validate the migrator parameters
        _validateMigratorParams(uint128(totalSupply), migrationParams);

        // Calculate the auctioned supply by subtracting the supply for LP and custody tokens from the total supply (checked to not underflow)
        uint256 auctionedSupply = totalSupply - migrationParams.supplyForLP - migrationParams.custodyTokens;

        // Ensure the auctioned supply is less than the maximum uint128 value to allow migration to a v4 pool
        // TODO: If CCA only requires auctionSupply <= uint128.max because of LP limits, we can remove this condition from here and CCA
        //       since the token amount going into the v4 pool is migrationParams.supplyForLP, which is enforced as uint128.
        if (auctionedSupply > type(uint128).max) revert InvalidAmount(auctionedSupply, type(uint128).max);

        // Deploy the initializer contract via factory
        ILBPInitializer initializer = ILBPInitializer(
            address(
                IDistributionStrategy(initializerFactory)
                    .initializeDistribution(
                        token,
                        auctionedSupply,
                        /* TODO: Add migrationParams.supplyForLP + migrationParams.custodyTokens, once CCA supports it */
                        _encodeAuctionParams(auctionParams),
                        bytes32(0)
                    )
            )
        );

        // Create the unique identifier for the auction by hashing the MigratorParameters struct
        bytes32 identifier = _createIdentifier(migrationParams);
        // Store the identifier for the initializer to validate migration parameters during migration
        initializers[initializer] = identifier;

        // TODO: does DistributionInitialized event make sense here?
        // Emit the distribution initialized event
        // emit DistributionInitialized(address(this), token, totalSupply);

        // Emit the auction initialized event to allow indexing all the migration and auction parameters
        emit InitializerCreated(initializer, migrationParams);

        return IDistributionContract(address(initializer));
    }

    /// @notice Migrates the raised funds and tokens to a v4 pool and sweep the raised funds, unsold and custody tokens to the fundsRecipient
    function migrate(ILBPInitializer initializer, MigratorParameters calldata migrationParams) external {
        // Ensure the migration block is after the current block
        if (_getBlockNumberish() < migrationParams.migrationBlock) {
            revert MigrationNotAllowed(migrationParams.migrationBlock, _getBlockNumberish());
        }

        // Get the identifier for the initializer
        bytes32 identifier = initializers[initializer];

        // Validate the migration parameters by comparing the stored identifier to the recreated identifier
        if (identifier != _createIdentifier(migrationParams)) {
            revert InvalidMigrationParameters();
        }

        // Get the LBP initialization parameters. Trust the initializer to return the correct parameters.
        LBPInitializationParams memory lbpParams = initializer.lbpInitializationParams();

        // Sweep the currency and tokens into the LBP strategy
        initializer.sweepCurrency();
        initializer.sweepToken();

        uint128 currencyAmountForLp =
            _calculateCurrencyAmountForLp(lbpParams.currencyRaised, migrationParams.currencySplitForLP);

        // Ensure the currency amount for the LP is in a valid range to create a v4 pool
        (uint128 actualCurrencyAmountForLp, uint128 currencyAmountAboveMax) =
            _validateCurrencyAmountForLp(currencyAmountForLp);
        if (currencyAmountAboveMax > 0) {
            // TODO: Discussion if amount above currency raised should be transferred to the funds recipient or revert.
            //       Connected to the discussion about the CCA limit of type(uint128).max currency amount.
            revert CurrencyAmountTooHigh(currencyAmountForLp, type(uint128).max);
        }
        currencyAmountForLp = actualCurrencyAmountForLp;

        Currency currency = Currency.wrap(initializer.currency());
        Currency token = Currency.wrap(initializer.token());

        // Prepare the migration data
        MigrationData memory data = _prepareMigrationData(
            address(currency),
            address(token),
            currencyAmountForLp,
            migrationParams.supplyForLP,
            lbpParams.initialPriceX96
        );

        PoolKey memory key = _initializePool(data);

        bytes memory plan = _createPositionPlan(data);

        // Transfer the assets to the position manager and execute the position plan. Reentrancy protected by Initializer.sweep
        _transferAssetsAndExecutePlan(
            currency, token, _getTokenTransferAmount(data), _getCurrencyTransferAmount(data), plan
        );

        // TODO: Implement fallback full range position plan into _transferAssetsAndExecutePlan if modify liquidities reverts

        // Transfer all leftover currency and tokens to the funds recipient (non LP currency and tokens, unsold & custody tokens and dust)
        uint256 remainingCurrency = currency.balanceOfSelf();
        if (remainingCurrency > 0) {
            // TODO: Handle blocked native currency transfers
            currency.transfer(migrationParams.fundsRecipient, remainingCurrency);
            emit CurrencySwept(migrationParams.fundsRecipient, remainingCurrency);
        }
        uint256 remainingToken = token.balanceOfSelf();
        if (remainingToken > 0) {
            token.transfer(migrationParams.fundsRecipient, remainingToken);
            emit TokensSwept(migrationParams.fundsRecipient, remainingToken);
        }

        emit Migrated(key, data.sqrtPriceX96);
    }

    /// @notice Initializes the pool with the calculated price
    /// @param _data Migration data containing the sqrt price
    /// @return key The pool key for the initialized pool
    function _initializePool(MigrationData memory _data) internal returns (PoolKey memory key) {
        key = PoolKey({
            currency0: _currency0(),
            currency1: _currency1(),
            fee: poolLPFee,
            tickSpacing: poolTickSpacing,
            hooks: IHooks(address(this))
        });

        // Initialize the pool with the returned initial price
        // Will revert if:
        //      - Pool is already initialized
        //      - Initial price is not set (sqrtPriceX96 = 0)
        poolManager.initialize(key, _data.sqrtPriceX96);

        return key;
    }

    /// @notice Transfers assets to position manager and executes the position plan
    /// @param _tokenTransferAmount The amount of tokens to transfer to the position manager
    /// @param _currencyTransferAmount The amount of currency to transfer to the position manager
    /// @param _plan The encoded position plan to execute
    function _transferAssetsAndExecutePlan(
        Currency currency,
        Currency token,
        uint128 _tokenTransferAmount,
        uint128 _currencyTransferAmount,
        bytes memory _plan
    ) internal {
        // Transfer tokens to position manager and execute the position plan via modifyLiquidities
        if (currency.isAddressZero()) {
            // Currency is native
            token.transfer(address(positionManager), _tokenTransferAmount);
            positionManager.modifyLiquidities{value: _currencyTransferAmount}(_plan, block.timestamp);
        } else if (token.isAddressZero()) {
            // Token is native
            currency.transfer(address(positionManager), _currencyTransferAmount);
            positionManager.modifyLiquidities{value: _tokenTransferAmount}(_plan, block.timestamp);
        } else {
            // Both are ERC20 tokens
            token.transfer(address(positionManager), _tokenTransferAmount);
            currency.transfer(address(positionManager), _currencyTransferAmount);
            positionManager.modifyLiquidities(_plan, block.timestamp);
        }
    }

    /// @notice Validates migration currency amount for the LP
    /// @param currencyAmountForLp The currency amount raised for the LP
    function _validateCurrencyAmountForLp(uint256 currencyAmountForLp)
        internal
        view
        returns (uint128 actualCurrencyAmountForLp, uint128 currencyAmountAboveMax)
    {
        // Cannot create a v4 pool with more than type(uint128).max currency amount
        if (currencyAmountForLp > type(uint128).max) {
            currencyAmountAboveMax = uint128(currencyAmountForLp - type(uint128).max);
            actualCurrencyAmountForLp = type(uint128).max;
        } else {
            actualCurrencyAmountForLp = uint128(currencyAmountForLp);
        }

        // Cannot create a v4 pool with no currency raised
        if (currencyAmountForLp == 0) {
            revert NoCurrencyRaised();
        }
    }

    /// @notice Prepares all migration data including prices, amounts, and liquidity calculations
    /// @param currencyAmountForLp The total currency amount for the LP
    /// @param initialPriceX96 The initial price of the pool
    /// @return data MigrationData struct containing all calculated values
    function _prepareMigrationData(
        address currency,
        address token,
        uint128 currencyAmountForLp,
        uint128 tokenAmountForLp,
        uint256 initialPriceX96
    ) internal view returns (MigrationData memory) {
        bool currencyIsCurrency0 = _currencyIsCurrency0(currency, token);

        uint256 priceX192 = initialPriceX96.convertToPriceX192(currencyIsCurrency0);
        uint160 sqrtPriceX96 = priceX192.convertToSqrtPriceX96();

        (uint128 fullRangeTokenAmount, uint128 fullRangeCurrencyAmount) =
            priceX192.calculateAmounts(currencyAmountForLp, currencyIsCurrency0, tokenAmountForLp);

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

    /// @notice Creates the position plan based on migration data
    /// @param _data Migration data with all necessary parameters
    /// @return plan The encoded position plan
    function _createPositionPlan(MigrationData memory _data) internal virtual returns (bytes memory plan) {
        // TODO: Implement the position plan creation via the PositionPlanner library
    }

    /// @notice Validates the migrator parameters and reverts if any are invalid. Continues if all are valid
    /// @param _totalSupply The total supply of the token that was sent to this contract to be distributed
    /// @param _migratorParams The migrator parameters that will be used to create the v4 pool and position
    function _validateMigratorParams(uint128 _totalSupply, MigratorParameters calldata _migratorParams) private pure {
        // token supply for the must LP cannot and the custody must be less than the total supply
        if (_migratorParams.supplyForLP + _migratorParams.custodyTokens > _totalSupply) {
            revert InvalidAmount(_migratorParams.supplyForLP, _totalSupply);
        }
        // max currency amount for LP cannot be smaller than the min split for LP or bigger than 100%
        (,, uint24 minSplitForLP) = _readSettings();
        if (_migratorParams.currencySplitForLP < minSplitForLP || _migratorParams.currencySplitForLP > 1e7) {
            revert InvalidCurrencySplitForLP(_migratorParams.currencySplitForLP, minSplitForLP, 1e7);
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

    function _calculateCurrencyAmountForLp(uint128 currencyAmount, uint24 currencySplitForLP)
        private
        pure
        returns (uint128 currencyAmountForLp)
    {
        currencyAmountForLp = currencyAmount * currencySplitForLP / 1e7;
    }

    function _readSettings() internal view returns (address protocolFeeController, uint24 minSplitForLP) {
        assembly ("memory-safe") {
            let slotContent := sload(settings.slot)
            protocolFeeController := and(slotContent, 0xffffffffffffffffffffffffffffffffffffffff)
            minSplitForLP := and(shr(160, slotContent), 0xffffffffffff)
        }
    }

    function _createIdentifier(MigratorParameters calldata migrationParams) private pure returns (bytes32 identifier) {
        assembly ("memory-safe") {
            // Load the free memory pointer to the next free slot
            let m := mload(0x40)
            // Copy the MigratorParameters struct to memory
            calldatacopy(
                m,
                migrationParams,
                0x140 /* length of MigratorParameters struct */
            )
            // Hash the MigratorParameters struct
            identifier := keccak256(m, 0x140)
        }
    }

    function _encodeAuctionParams(AuctionParameters calldata auctionParams)
        private
        pure
        returns (bytes calldata encodedAuctionParams)
    {
        // AuctionParameters struct layout:
        //
        // 0x00 currency
        // 0x20 tokensRecipient
        // 0x40 fundsRecipient
        // 0x60 startBlock
        // 0x80 endBlock
        // 0xa0 claimBlock
        // 0xc0 tickSpacing
        // 0xe0 validationHook
        // 0x100 floorPrice
        // 0x120 requiredCurrencyRaised
        // 0x140 auctionStepsData.offset
        // 0x160 auctionStepsData.length
        // 0x180 auctionStepsData.content (if length > 0)
        // ...
        //
        // Total length: 0x180 + rounded up auctionStepsData.length

        assembly ("memory-safe") {
            // Get the length of the auction steps data since its variable
            let auctionStepsDataLength := calldataload(add(auctionParams, 0x160))
            // Normalize the length to be a multiple of 32
            auctionStepsDataLength := and(add(auctionStepsDataLength, 0x1f), not(0x1f))
            let bytesLength := add(0x180, auctionStepsDataLength)
            encodedAuctionParams.length := bytesLength
            encodedAuctionParams.offset := auctionParams
        }
    }

    function _currencyIsCurrency0(address currency, address token) internal view returns (bool) {
        return currency < poolToken;
    }
}
