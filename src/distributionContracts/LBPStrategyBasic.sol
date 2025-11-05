// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAuction, AuctionParameters} from "twap-auction/src/interfaces/IAuction.sol";
import {Auction} from "twap-auction/src/Auction.sol";
import {IAuctionFactory} from "twap-auction/src/interfaces/IAuctionFactory.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {SafeERC20} from "@openzeppelin-latest/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin-latest/contracts/token/ERC20/IERC20.sol";
import {IDistributionContract} from "../interfaces/IDistributionContract.sol";
import {MigratorParameters} from "../types/MigratorParameters.sol";
import {ILBPStrategyBasic} from "../interfaces/ILBPStrategyBasic.sol";
import {HookBasic} from "../utils/HookBasic.sol";
import {TickCalculations} from "../libraries/TickCalculations.sol";
import {TokenPricing} from "../libraries/TokenPricing.sol";
import {StrategyPlanner} from "../libraries/StrategyPlanner.sol";
import {BasePositionParams, FullRangeParams, OneSidedParams} from "../types/PositionTypes.sol";
import {ParamsBuilder} from "../libraries/ParamsBuilder.sol";
import {MigrationData} from "../types/MigrationData.sol";
import {TokenDistribution} from "../libraries/TokenDistribution.sol";

/// @title LBPStrategyBasic
/// @notice Basic Strategy to distribute tokens and raise funds from an auction to a v4 pool
/// @custom:security-contact security@uniswap.org
contract LBPStrategyBasic is ILBPStrategyBasic, HookBasic {
    using SafeERC20 for IERC20;
    using TickCalculations for int24;
    using CurrencyLibrary for Currency;
    using StrategyPlanner for BasePositionParams;
    using TokenDistribution for uint128;
    using TokenPricing for *;

    /// @notice The token that is being distributed
    address public immutable token;
    /// @notice The currency that the auction raised funds in
    address public immutable currency;

    /// @notice The LP fee that the v4 pool will use expressed in hundredths of a bip (1e6 = 100%)
    uint24 public immutable poolLPFee;
    /// @notice The tick spacing that the v4 pool will use
    int24 public immutable poolTickSpacing;

    /// @notice The supply of the token that was sent to this contract to be distributed
    uint128 public immutable totalSupply;
    /// @notice The remaining supply of the token that was not sent to the auction
    uint128 public immutable reserveSupply;
    /// @notice The address that will receive the position
    address public immutable positionRecipient;
    /// @notice The block number at which migration is allowed
    uint64 public immutable migrationBlock;
    /// @notice The auction factory that will be used to create the auction
    address public immutable auctionFactory;
    /// @notice The operator that can sweep currency and tokens from the pool after sweepBlock
    address public immutable operator;
    /// @notice The block number at which the operator can sweep currency and tokens from the pool
    uint64 public immutable sweepBlock;
    /// @notice Whether to create a one sided position in the token after the full range position
    bool public immutable createOneSidedTokenPosition;
    /// @notice Whether to create a one sided position in the currency after the full range position
    bool public immutable createOneSidedCurrencyPosition;
    /// @notice The position manager that will be used to create the position
    IPositionManager public immutable positionManager;

    /// @notice The auction that will be used to create the auction
    IAuction public auction;
    bytes public auctionParameters;

    constructor(
        address _token,
        uint128 _totalSupply,
        MigratorParameters memory _migratorParams,
        bytes memory _auctionParams,
        IPositionManager _positionManager,
        IPoolManager _poolManager
    ) HookBasic(_poolManager) {
        _validateMigratorParams(_token, _totalSupply, _migratorParams);
        _validateAuctionParams(_auctionParams, _migratorParams);

        auctionParameters = _auctionParams;

        token = _token;
        currency = _migratorParams.currency;
        totalSupply = _totalSupply;
        // Calculate tokens reserved for liquidity by subtracting tokens allocated for auction
        //   e.g. if tokenSplitToAuction = 5e6 (50%), then half goes to auction and half is reserved
        reserveSupply = _totalSupply.calculateReserveSupply(_migratorParams.tokenSplitToAuction);
        positionManager = _positionManager;
        positionRecipient = _migratorParams.positionRecipient;
        migrationBlock = _migratorParams.migrationBlock;
        auctionFactory = _migratorParams.auctionFactory;
        poolLPFee = _migratorParams.poolLPFee;
        poolTickSpacing = _migratorParams.poolTickSpacing;
        operator = _migratorParams.operator;
        sweepBlock = _migratorParams.sweepBlock;
        createOneSidedTokenPosition = _migratorParams.createOneSidedTokenPosition;
        createOneSidedCurrencyPosition = _migratorParams.createOneSidedCurrencyPosition;
    }

    /// @notice Gets the address of the token that will be used to create the pool
    /// @return The address of the token that will be used to create the pool
    function getPoolToken() internal view virtual returns (address) {
        return token;
    }

    /// @inheritdoc IDistributionContract
    function onTokensReceived() external {
        if (IERC20(token).balanceOf(address(this)) < totalSupply) {
            revert InvalidAmountReceived(totalSupply, IERC20(token).balanceOf(address(this)));
        }

        uint128 auctionSupply = totalSupply - reserveSupply;

        IAuction _auction = IAuction(
            address(
                IAuctionFactory(auctionFactory)
                    .initializeDistribution(token, auctionSupply, auctionParameters, bytes32(0))
            )
        );

        Currency.wrap(token).transfer(address(_auction), auctionSupply);
        _auction.onTokensReceived();
        auction = _auction;

        emit AuctionCreated(address(_auction));
    }

    /// @inheritdoc ILBPStrategyBasic
    function migrate() external {
        _validateMigration();

        MigrationData memory data = _prepareMigrationData();

        PoolKey memory key = _initializePool(data);

        bytes memory plan = _createPositionPlan(data);

        _transferAssetsAndExecutePlan(data, plan);

        emit Migrated(key, data.sqrtPriceX96);
    }

    /// @inheritdoc ILBPStrategyBasic
    function sweepToken() external {
        if (block.number < sweepBlock) revert SweepNotAllowed(sweepBlock, block.number);
        if (msg.sender != operator) revert NotOperator(msg.sender, operator);

        uint256 tokenBalance = Currency.wrap(token).balanceOf(address(this));
        if (tokenBalance > 0) {
            Currency.wrap(token).transfer(operator, tokenBalance);
            emit TokensSwept(operator, tokenBalance);
        }
    }

    /// @inheritdoc ILBPStrategyBasic
    function sweepCurrency() external {
        if (block.number < sweepBlock) revert SweepNotAllowed(sweepBlock, block.number);
        if (msg.sender != operator) revert NotOperator(msg.sender, operator);

        uint256 currencyBalance = Currency.wrap(currency).balanceOf(address(this));
        if (currencyBalance > 0) {
            Currency.wrap(currency).transfer(operator, currencyBalance);
            emit CurrencySwept(operator, currencyBalance);
        }
    }

    /// @notice Validates the migrator parameters and reverts if any are invalid. Continues if all are valid
    /// @param _token The token that is being distributed
    /// @param _totalSupply The total supply of the token that was sent to this contract to be distributed
    /// @param migratorParams The migrator parameters that will be used to create the v4 pool and position
    function _validateMigratorParams(address _token, uint128 _totalSupply, MigratorParameters memory migratorParams)
        private
        pure
    {
        // sweep block validation (cannot be before or equal to the migration block)
        if (migratorParams.sweepBlock <= migratorParams.migrationBlock) {
            revert InvalidSweepBlock(migratorParams.sweepBlock, migratorParams.migrationBlock);
        }
        // token split validation (cannot be greater than or equal to 100%)
        else if (migratorParams.tokenSplitToAuction >= TokenDistribution.MAX_TOKEN_SPLIT) {
            revert TokenSplitTooHigh(migratorParams.tokenSplitToAuction, TokenDistribution.MAX_TOKEN_SPLIT);
        }
        // token validation (cannot be zero address or the same as the currency)
        else if (_token == address(0) || _token == migratorParams.currency) {
            revert InvalidToken(address(_token));
        }
        // tick spacing validation (cannot be greater than the v4 max tick spacing or less than the v4 min tick spacing)
        else if (
            migratorParams.poolTickSpacing > TickMath.MAX_TICK_SPACING
                || migratorParams.poolTickSpacing < TickMath.MIN_TICK_SPACING
        ) {
            revert InvalidTickSpacing(
                migratorParams.poolTickSpacing, TickMath.MIN_TICK_SPACING, TickMath.MAX_TICK_SPACING
            );
        }
        // fee validation (cannot be greater than the v4 max fee)
        else if (migratorParams.poolLPFee > LPFeeLibrary.MAX_LP_FEE) {
            revert InvalidFee(migratorParams.poolLPFee, LPFeeLibrary.MAX_LP_FEE);
        }
        // position recipient validation (cannot be zero address, address(1), or address(2) which are reserved addresses on the position manager)
        else if (
            migratorParams.positionRecipient == address(0)
                || migratorParams.positionRecipient == ActionConstants.MSG_SENDER
                || migratorParams.positionRecipient == ActionConstants.ADDRESS_THIS
        ) {
            revert InvalidPositionRecipient(migratorParams.positionRecipient);
        }
        // auction supply validation (cannot be zero)
        else if (_totalSupply.calculateAuctionSupply(migratorParams.tokenSplitToAuction) == 0) {
            revert AuctionSupplyIsZero();
        }
    }

    /// @notice Validates that the funds recipient in the auction parameters is set to ActionConstants.MSG_SENDER (address(1)),
    ///         which will be replaced with this contract's address by the AuctionFactory during auction creation
    ///         Also validates that the migration block is after the end block of the auction.
    /// @dev Will revert if the parameters are not correcly encoded for AuctionParameters
    /// @param auctionParams The auction parameters that will be used to create the auction
    function _validateAuctionParams(bytes memory auctionParams, MigratorParameters memory migratorParams) private pure {
        AuctionParameters memory _auctionParams = abi.decode(auctionParams, (AuctionParameters));
        if (_auctionParams.fundsRecipient != ActionConstants.MSG_SENDER) {
            revert InvalidFundsRecipient(_auctionParams.fundsRecipient, ActionConstants.MSG_SENDER);
        } else if (_auctionParams.endBlock >= migratorParams.migrationBlock) {
            revert InvalidEndBlock(_auctionParams.endBlock, migratorParams.migrationBlock);
        }
    }

    /// @notice Validates migration timing and currency balance
    function _validateMigration() internal virtual {
        if (block.number < migrationBlock) {
            revert MigrationNotAllowed(migrationBlock, block.number);
        }

        // call checkpoint to get the final currency raised and clearing price
        auction.checkpoint();
        uint256 currencyAmount = auction.currencyRaised();

        if (currencyAmount > type(uint128).max) {
            revert CurrencyAmountTooHigh(currencyAmount, type(uint128).max);
        }

        if (currencyAmount == 0) {
            revert NoCurrencyRaised();
        }

        if (Currency.wrap(currency).balanceOf(address(this)) < currencyAmount) {
            revert InsufficientCurrency(currencyAmount, Currency.wrap(currency).balanceOf(address(this)));
        }
    }

    /// @notice Prepares all migration data including prices, amounts, and liquidity calculations
    /// @return data MigrationData struct containing all calculated values
    function _prepareMigrationData() private view returns (MigrationData memory data) {
        uint128 currencyRaised = uint128(auction.currencyRaised()); // already validated to be less than or equal to type(uint128).max
        address poolToken = getPoolToken();

        uint256 priceX192 = auction.clearingPrice().convertToPriceX192(currency < poolToken);

        data.sqrtPriceX96 = priceX192.convertToSqrtPriceX96();

        (data.initialTokenAmount, data.leftoverCurrency, data.initialCurrencyAmount) =
            priceX192.calculateAmounts(currencyRaised, currency < poolToken, reserveSupply);

        data.liquidity = LiquidityAmounts.getLiquidityForAmounts(
            data.sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(poolTickSpacing)),
            TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(poolTickSpacing)),
            currency < poolToken ? data.initialCurrencyAmount : data.initialTokenAmount,
            currency < poolToken ? data.initialTokenAmount : data.initialCurrencyAmount
        );

        // Determine if we should create a one-sided position in tokens if createOneSidedTokenPosition is set OR
        // if we should create a one-sided position in currency if createOneSidedCurrencyPosition is set and there is leftover currency
        data.shouldCreateOneSided = createOneSidedTokenPosition && reserveSupply > data.initialTokenAmount
            || createOneSidedCurrencyPosition && data.leftoverCurrency > 0;

        return data;
    }

    /// @notice Initializes the pool with the calculated price
    /// @param data Migration data containing the sqrt price
    /// @return key The pool key for the initialized pool
    function _initializePool(MigrationData memory data) private returns (PoolKey memory key) {
        address poolToken = getPoolToken();

        key = PoolKey({
            currency0: Currency.wrap(currency < poolToken ? currency : poolToken),
            currency1: Currency.wrap(currency < poolToken ? poolToken : currency),
            fee: poolLPFee,
            tickSpacing: poolTickSpacing,
            hooks: IHooks(address(this))
        });

        // Initialize the pool with the starting price determined by the auction
        // Will revert if:
        //      - Pool is already initialized
        //      - Initial price is not set (sqrtPriceX96 = 0)
        poolManager.initialize(key, data.sqrtPriceX96);

        return key;
    }

    /// @notice Creates the position plan based on migration data
    /// @param data Migration data with all necessary parameters
    /// @return plan The encoded position plan
    function _createPositionPlan(MigrationData memory data) private view returns (bytes memory plan) {
        bytes memory actions;
        bytes[] memory params;

        address poolToken = getPoolToken();

        // Create base parameters
        BasePositionParams memory baseParams = BasePositionParams({
            currency: currency,
            token: poolToken,
            poolLPFee: poolLPFee,
            poolTickSpacing: poolTickSpacing,
            initialSqrtPriceX96: data.sqrtPriceX96,
            liquidity: data.liquidity,
            positionRecipient: positionRecipient,
            hooks: IHooks(address(this))
        });

        if (data.shouldCreateOneSided) {
            (actions, params) = _createFullRangePositionPlan(
                baseParams,
                data.initialTokenAmount,
                data.initialCurrencyAmount,
                ParamsBuilder.FULL_RANGE_WITH_ONE_SIDED_SIZE
            );
            (actions, params) = _createOneSidedPositionPlan(
                baseParams, actions, params, data.initialTokenAmount, data.leftoverCurrency
            );
            // shouldCreatedOneSided could be true, but if the one sided position is not valid, only a full range position will be created and there will be no one sided params
            data.hasOneSidedParams = params.length == ParamsBuilder.FULL_RANGE_WITH_ONE_SIDED_SIZE;
        } else {
            (actions, params) = _createFullRangePositionPlan(
                baseParams, data.initialTokenAmount, data.initialCurrencyAmount, ParamsBuilder.FULL_RANGE_SIZE
            );
        }

        (actions, params) = _createFinalTakePairPlan(baseParams, actions, params);

        return abi.encode(actions, params);
    }

    /// @notice Transfers assets to position manager and executes the position plan
    /// @param data Migration data with amounts and flags
    /// @param plan The encoded position plan to execute
    function _transferAssetsAndExecutePlan(MigrationData memory data, bytes memory plan) private {
        // Calculate token amount to transfer
        uint128 tokenTransferAmount = _getTokenTransferAmount(data);

        // Transfer tokens to position manager
        Currency.wrap(token).transfer(address(positionManager), tokenTransferAmount);

        // Calculate currency amount and execute plan
        uint128 currencyTransferAmount = _getCurrencyTransferAmount(data);

        if (Currency.wrap(currency).isAddressZero()) {
            // Native currency: send as value with modifyLiquidities call
            positionManager.modifyLiquidities{value: currencyTransferAmount}(plan, block.timestamp);
        } else {
            // Non-native currency: transfer first, then call modifyLiquidities
            Currency.wrap(currency).transfer(address(positionManager), currencyTransferAmount);
            positionManager.modifyLiquidities(plan, block.timestamp);
        }
    }

    /// @notice Calculates the amount of tokens to transfer
    /// @param data Migration data
    /// @return The amount of tokens to transfer to the position manager
    function _getTokenTransferAmount(MigrationData memory data) private view returns (uint128) {
        // hasOneSidedParams can only be true if shouldCreateOneSided is true
        return
            (reserveSupply > data.initialTokenAmount && data.hasOneSidedParams)
                ? reserveSupply
                : data.initialTokenAmount;
    }

    /// @notice Calculates the amount of currency to transfer
    /// @param data Migration data
    /// @return The amount of currency to transfer to the position manager
    function _getCurrencyTransferAmount(MigrationData memory data) private pure returns (uint128) {
        // hasOneSidedParams can only be true if shouldCreateOneSided is true
        return (data.leftoverCurrency > 0 && data.hasOneSidedParams)
            ? data.initialCurrencyAmount + data.leftoverCurrency
            : data.initialCurrencyAmount;
    }

    /// @notice Creates the plan for creating a full range v4 position using the position manager
    /// @param baseParams The base parameters for the position
    /// @param tokenAmount The amount of token to be used to create the position
    /// @param currencyAmount The amount of currency to be used to create the position
    /// @param paramsArraySize The size of the parameters array (either 5 or 8)
    /// @return The actions and parameters for the position
    function _createFullRangePositionPlan(
        BasePositionParams memory baseParams,
        uint128 tokenAmount,
        uint128 currencyAmount,
        uint256 paramsArraySize
    ) private pure returns (bytes memory, bytes[] memory) {
        // Create full range specific parameters
        FullRangeParams memory fullRangeParams =
            FullRangeParams({tokenAmount: tokenAmount, currencyAmount: currencyAmount});

        // Plan the full range position
        return baseParams.planFullRangePosition(fullRangeParams, paramsArraySize);
    }

    /// @notice Creates the plan for creating a one sided v4 position using the position manager along with the full range position
    /// @param baseParams The base parameters for the position
    /// @param actions The existing actions for the full range position which may be extended with the new actions for the one sided position
    /// @param params The existing parameters for the full range position which may be extended with the new parameters for the one sided position
    /// @param tokenAmount The amount of token to be used to create the position
    /// @param leftoverCurrency The amount of currency that was leftover from the full range position
    /// @return The actions and parameters needed to create the full range position and the one sided position
    function _createOneSidedPositionPlan(
        BasePositionParams memory baseParams,
        bytes memory actions,
        bytes[] memory params,
        uint128 tokenAmount,
        uint128 leftoverCurrency
    ) private view returns (bytes memory, bytes[] memory) {
        // reserveSupply - tokenAmount will not underflow because of validation in TokenPricing.calculateAmounts()
        uint128 amount = leftoverCurrency > 0 ? leftoverCurrency : reserveSupply - tokenAmount;
        bool inToken = leftoverCurrency == 0;

        // Create one-sided specific parameters
        OneSidedParams memory oneSidedParams = OneSidedParams({amount: amount, inToken: inToken});

        // Plan the one-sided position
        return baseParams.planOneSidedPosition(oneSidedParams, actions, params);
    }

    /// @notice Creates the plan for taking the pair using the position manager
    /// @param baseParams The base parameters for the position
    /// @param actions The existing actions for the position which may be extended with the new actions for the final take pair
    /// @param params The existing parameters for the position which may be extended with the new parameters for the final take pair
    /// @return The actions and parameters needed to take the pair using the position manager
    function _createFinalTakePairPlan(BasePositionParams memory baseParams, bytes memory actions, bytes[] memory params)
        private
        view
        returns (bytes memory, bytes[] memory)
    {
        return baseParams.planFinalTakePair(actions, params);
    }

    /// @notice Receives native currency
    receive() external payable {}
}
