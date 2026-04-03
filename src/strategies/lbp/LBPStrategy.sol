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
import {Ownable} from "solady/auth/Ownable.sol";
// import {AuctionParameters} from "continuous-clearing-auction/src/interfaces/IContinuousClearingAuction.sol";
import {AuctionParameters} from "../../interfaces/ILBPStrategy.sol";
import {TokenPricing} from "../../libraries/TokenPricing.sol";
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
    struct OwnerControlled {
        address protocolFeeController; // the address defining the protocol fee payed on non-LP currency
        uint24 minSplitForLP; // the minimum percentage (in mps) of the total supply of the token that must be sent to an LP
    }

    IPoolManager public immutable poolManager;
    IPositionManager public immutable positionManager;
    IDistributionStrategy public immutable initializerFactory;

    // Owner controlled parameters
    OwnerControlled public ownerControlledParams;

    /// @notice The mapping of initializers to their identifiers ensuring the validity of provided calldata during migration
    mapping(ILBPInitializer initializer => bytes32 identifier) public initializers;

    // TODO: Add functionality to fully replace GovernedLBPStrategy

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

    function setOwnerControlledParams(OwnerControlled calldata _ownerControlledParams) external onlyOwner {
        if (_ownerControlledParams.protocolFeeController == address(0) || _ownerControlledParams.minSplitForLP == 0) {
            revert InvalidOwnerControlledParams();
        }
        ownerControlledParams = _ownerControlledParams;
        emit OwnerControlledParamsSet(
            _ownerControlledParams.protocolFeeController, _ownerControlledParams.minSplitForLP
        );
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

        // Validate the auction parameters
        _validateAuctionParams(totalSupply, auctionParams, migrationParams);

        // Validate the migrator parameters
        _validateMigratorParams(migrationParams);

        // Subtract custody tokens so the CCA only auctions the remaining portion.
        uint256 auctionedSupply = totalSupply - auctionParams.custodyTokens;
        // Deploy the initializer contract via factory
        ILBPInitializer initializer = ILBPInitializer(
            address(
                IDistributionStrategy(initializerFactory)
                    .initializeDistribution(token, auctionedSupply, _encodeAuctionParams(auctionParams), bytes32(0))
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

        // Delete the initializer from the mapping to save gas
        delete initializers[initializer];

        // Validate the migration parameters by comparing the stored identifier to the recreated identifier
        if (identifier != _createIdentifier(migrationParams)) {
            revert InvalidMigrationParameters();
        }

        // Get the LBP initialization parameters. Trust the initializer to return the correct parameters.
        LBPInitializationParams memory lbpParams = initializer.lbpInitializationParams();

        // Sweep the currency and tokens into the LBP strategy
        initializer.sweepCurrency();
        initializer.sweepUnsoldTokens();

        uint256 currencyAmountForLp =
            _calculateCurrencyAmountForLp(lbpParams.currencyRaised, migrationParams.currencySplitForLP);

        // Ensure the currency amount for the LP is in a valid range to create a v4 pool
        (uint128 actualCurrencyAmountForLp, uint256 currencyAmountAboveMax) =
            _validateCurrencyAmountForLp(currencyAmountForLp);
        if (currencyAmountAboveMax > 0) {
            // TODO: Discussion if amount above currency raised should be transferred to the funds recipient or revert.
            //       Connected to the discussion about the CCA limit of type(uint128).max currency amount.
            revert CurrencyAmountTooHigh(currencyAmountForLp, type(uint128).max);
        }
        currencyAmountForLp = actualCurrencyAmountForLp;

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
            data, currency, token, migrationParams.poolLPFee, migrationParams.poolTickSpacing, migrationParams.lpHook
        );

        (bytes memory plan, uint128 currencyTransferAmount, uint128 tokenTransferAmount) = _createPositionPlan(data);

        // Transfer the assets to the position manager and execute the position plan. Reentrancy protected by Initializer.sweep
        _transferAssetsAndExecutePlan(currency, token, currencyTransferAmount, tokenTransferAmount, plan);

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
    /// @param _data Migration data containing the sqrt price
    /// @return key The pool key for the initialized pool
    function _initializePool(
        MigrationData memory _data,
        Currency currency,
        Currency token,
        uint24 poolLPFee,
        int24 poolTickSpacing,
        address lpHook
    ) private returns (PoolKey memory key) {
        key = PoolKey({
            currency0: _currency0(currency, token),
            currency1: _currency1(currency, token),
            fee: poolLPFee,
            tickSpacing: poolTickSpacing,
            hooks: IHooks(lpHook)
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
    ) private {
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

    /// @notice Validates the migrator parameters and reverts if any are invalid. Continues if all are valid
    /// @param _migratorParams The migrator parameters that will be used to create the v4 pool and position
    function _validateMigratorParams(MigratorParameters calldata _migratorParams) private view {
        // Ensure the token supply for the LP and the custody tokens combined are less than or equal to type(uint128).max
        if (uint256(_migratorParams.supplyForLP) + uint256(_migratorParams.custodyTokens) > type(uint128).max) {
            revert InvalidCustodySupply(
                uint256(_migratorParams.supplyForLP) + uint256(_migratorParams.custodyTokens), type(uint128).max
            );
        }
        // max currency amount for LP cannot be zero, smaller than the min split for LP or bigger than 100%
        (, uint24 minSplitForLP) = _readOwnerControlledParams();
        if (
            _migratorParams.currencySplitForLP == 0 || _migratorParams.currencySplitForLP < minSplitForLP
                || _migratorParams.currencySplitForLP > 1e7
        ) {
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

    /// @notice Validates the auction parameters and reverts if any are invalid. Continues if all are valid
    /// @param totalSupply The total supply of the token that will be used in the initializer for price discovery
    /// @param auctionParams The auction parameters that will be used to create the v4 pool and position
    /// @param migrationParams The migrator parameters that will be used to create the v4 pool and position
    function _validateAuctionParams(
        uint256 totalSupply,
        AuctionParameters calldata auctionParams,
        MigratorParameters calldata migrationParams
    ) private view {
        // Ensure the funds recipient is this contract
        if (auctionParams.fundsRecipient != address(this) || auctionParams.tokensRecipient != address(this)) {
            revert InvalidRecipient(address(this));
        }
        // Ensure the migration block is after the end block to ensure a successful migration
        if (auctionParams.endBlock >= migrationParams.migrationBlock) {
            revert InvalidEndBlock(auctionParams.endBlock, migrationParams.migrationBlock);
        }
        // Ensure the custody tokens are correct inside the auction parameters
        uint256 expectedCustodyTokens = migrationParams.supplyForLP + migrationParams.custodyTokens;
        // Ensure the custody tokens are correct inside the auction parameters
        if (auctionParams.custodyTokens != expectedCustodyTokens) {
            revert InvalidCustodySupply(auctionParams.custodyTokens, expectedCustodyTokens);
        }
        // totalSupply includes auctioned tokens + custody tokens (supplyForLP + custodyTokens), so it must be greater
        if (totalSupply <= expectedCustodyTokens) {
            revert InvalidTotalSupply(totalSupply, expectedCustodyTokens);
        }
        // Ensure the auctioned supply is less than the maximum uint128 value to allow migration to a v4 pool
        // TODO: If CCA only requires auctionSupply <= uint128.max because of LP limits, we can remove this condition from here and CCA
        //       since the token amount going into the v4 pool is migrationParams.supplyForLP, which is enforced as uint128.
        if (totalSupply - expectedCustodyTokens > type(uint128).max) {
            revert InvalidTotalSupply(totalSupply, type(uint128).max);
        }
    }

    function _readOwnerControlledParams() private view returns (address protocolFeeController, uint24 minSplitForLP) {
        assembly ("memory-safe") {
            let slotContent := sload(ownerControlledParams.slot)
            protocolFeeController := and(
                slotContent,
                0xffffffffffffffffffffffffffffffffffffffff /* address mask */
            )
            minSplitForLP := and(
                shr(160, slotContent),
                0xffffff /* uint24 mask */
            )
        }
    }

    /// @notice Validates migration currency amount for the LP
    /// @param currencyAmountForLp The currency amount raised for the LP
    function _validateCurrencyAmountForLp(uint256 currencyAmountForLp)
        private
        pure
        returns (uint128 actualCurrencyAmountForLp, uint256 currencyAmountAboveMax)
    {
        // Cannot create a v4 pool with more than type(uint128).max currency amount
        if (currencyAmountForLp > type(uint128).max) {
            currencyAmountAboveMax = currencyAmountForLp - type(uint128).max;
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
        currencyAmountForLp = currencyAmount * currencySplitForLP / 1e7;
    }

    function _createIdentifier(MigratorParameters calldata migrationParams) private pure returns (bytes32 identifier) {
        assembly ("memory-safe") {
            // Load the free memory pointer to the next free slot
            let m := mload(0x40)
            // Copy the MigratorParameters struct to memory
            calldatacopy(
                m,
                migrationParams,
                0x120 /* length of MigratorParameters struct */
            )
            // Hash the MigratorParameters struct
            identifier := keccak256(m, 0x120)
        }
    }

    function _encodeAuctionParams(AuctionParameters calldata auctionParams)
        private
        pure
        returns (bytes calldata encodedAuctionParams)
    {
        // AuctionParameters struct layout:
        //
        // 0x00 address currency
        // 0x20 uint128 custodyTokens
        // 0x40 address tokensRecipient
        // 0x60 address fundsRecipient
        // 0x80 uint64 startBlock
        // 0xa0 uint64 endBlock
        // 0xc0 uint64 claimBlock
        // 0xe0 uint256 tickSpacing
        // 0x100 address validationHook
        // 0x120 uint256 floorPrice
        // 0x140 uint128 requiredCurrencyRaised
        // 0x160 bytes auctionStepsData.offset
        // 0x180 bytes auctionStepsData.length
        // 0x1a0 bytes auctionStepsData.content (if length > 0)
        // ...
        //
        // Total length: 0x1a0 + rounded up auctionStepsData.length

        assembly ("memory-safe") {
            // Get the length of the auction steps data since its variable
            let auctionStepsDataLength := calldataload(add(auctionParams, 0x180))
            // Normalize the length to be a multiple of 32
            auctionStepsDataLength := and(add(auctionStepsDataLength, 0x1f), not(0x1f))
            let bytesLength := add(0x1a0, auctionStepsDataLength)
            encodedAuctionParams.length := bytesLength
            encodedAuctionParams.offset := auctionParams
        }
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
