// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

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
import {IAuction} from "twap-auction/src/interfaces/IAuction.sol";
import {IAuctionFactory} from "twap-auction/src/interfaces/IAuctionFactory.sol";
import {IDistributionContract} from "../interfaces/IDistributionContract.sol";
import {MigratorParameters} from "../types/MigratorParams.sol";
import {ILBPStrategyBasic} from "../interfaces/ILBPStrategyBasic.sol";
import {HookBasic} from "../utils/HookBasic.sol";
import {TickCalculations} from "../libraries/TickCalculations.sol";
import {TokenPricing} from "../libraries/TokenPricing.sol";
import {StrategyPlanner} from "../libraries/StrategyPlanner.sol";
import {BasePositionParams, FullRangeParams, OneSidedParams} from "../types/PositionTypes.sol";
import {ParamsBuilder} from "../libraries/ParamsBuilder.sol";
import {MigrationData} from "../types/MigrationData.sol";

/// @title LBPStrategyBasic
/// @notice Basic Strategy to distribute tokens and raise funds from an auction to a v4 pool
contract LBPStrategyBasic is ILBPStrategyBasic, HookBasic {
    using SafeERC20 for IERC20;
    using TickCalculations for int24;
    using CurrencyLibrary for Currency;
    using StrategyPlanner for BasePositionParams;
    using TokenPricing for *;

    /// @notice The token split is measured in bips (10_000 = 100%)
    uint16 public constant MAX_TOKEN_SPLIT = 10_000;

    address public immutable token;
    address public immutable currency;

    uint24 public immutable poolLPFee;
    int24 public immutable poolTickSpacing;

    uint128 public immutable totalSupply;
    uint128 public immutable reserveSupply;
    address public immutable positionRecipient;
    uint64 public immutable migrationBlock;
    address public immutable auctionFactory;
    address public immutable operator;
    uint64 public immutable sweepBlock;
    bool public immutable createOneSidedPosition;
    IPositionManager public immutable positionManager;

    IAuction public auction;
    bytes public auctionParameters;

    constructor(
        address _token,
        uint128 _totalSupply,
        MigratorParameters memory migratorParams,
        bytes memory auctionParams,
        IPositionManager _positionManager,
        IPoolManager _poolManager
    ) HookBasic(_poolManager) {
        _validateMigratorParams(_token, _totalSupply, migratorParams);

        auctionParameters = auctionParams;

        token = _token;
        currency = migratorParams.currency;
        totalSupply = _totalSupply;
        // Calculate tokens reserved for liquidity by subtracting tokens allocated for auction
        // e.g. if tokenSplitToAuction = 5000 (50%), then half goes to auction and half is reserved
        reserveSupply = _totalSupply
            - uint128(uint256(_totalSupply) * uint256(migratorParams.tokenSplitToAuction) / MAX_TOKEN_SPLIT);
        positionManager = _positionManager;
        positionRecipient = migratorParams.positionRecipient;
        migrationBlock = migratorParams.migrationBlock;
        auctionFactory = migratorParams.auctionFactory;
        operator = migratorParams.operator;
        sweepBlock = migratorParams.sweepBlock;
        poolLPFee = migratorParams.poolLPFee;
        poolTickSpacing = migratorParams.poolTickSpacing;
        createOneSidedPosition = migratorParams.createOneSidedPosition;
    }

    /// @inheritdoc IDistributionContract
    function onTokensReceived() external {
        if (IERC20(token).balanceOf(address(this)) < totalSupply) {
            revert InvalidAmountReceived(totalSupply, IERC20(token).balanceOf(address(this)));
        }

        uint128 auctionSupply = totalSupply - reserveSupply;

        auction = IAuction(
            address(
                IAuctionFactory(auctionFactory).initializeDistribution(
                    token, auctionSupply, auctionParameters, bytes32(0)
                )
            )
        );

        Currency.wrap(token).transfer(address(auction), auctionSupply);
        auction.onTokensReceived();
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

    function _validateMigratorParams(address _token, uint128 _totalSupply, MigratorParameters memory migratorParams)
        private
        pure
    {
        if (migratorParams.sweepBlock <= migratorParams.migrationBlock) {
            revert InvalidSweepBlock(migratorParams.sweepBlock, migratorParams.migrationBlock);
        }

        if (migratorParams.tokenSplitToAuction > MAX_TOKEN_SPLIT) {
            revert TokenSplitTooHigh(migratorParams.tokenSplitToAuction);
        }
        if (
            migratorParams.poolTickSpacing > TickMath.MAX_TICK_SPACING
                || migratorParams.poolTickSpacing < TickMath.MIN_TICK_SPACING
        ) revert InvalidTickSpacing(migratorParams.poolTickSpacing);
        if (migratorParams.poolLPFee > LPFeeLibrary.MAX_LP_FEE) revert InvalidFee(migratorParams.poolLPFee);
        if (
            migratorParams.positionRecipient == address(0)
                || migratorParams.positionRecipient == ActionConstants.MSG_SENDER
                || migratorParams.positionRecipient == ActionConstants.ADDRESS_THIS
        ) revert InvalidPositionRecipient(migratorParams.positionRecipient);
        if (_token == migratorParams.currency) {
            revert InvalidTokenAndCurrency(_token);
        }
        if (uint128(uint256(_totalSupply) * uint256(migratorParams.tokenSplitToAuction) / MAX_TOKEN_SPLIT) == 0) {
            revert AuctionSupplyIsZero();
        }
    }

    /// @notice Validates migration timing and currency balance
    function _validateMigration() private view {
        if (block.number < migrationBlock) {
            revert MigrationNotAllowed(migrationBlock, block.number);
        }

        uint128 currencyAmount = auction.currencyRaised();

        if (Currency.wrap(currency).balanceOf(address(this)) < currencyAmount) {
            revert InsufficientCurrency(currencyAmount, uint128(Currency.wrap(currency).balanceOf(address(this))));
        }
    }

    /// @notice Prepares all migration data including prices, amounts, and liquidity calculations
    /// @return data MigrationData struct containing all calculated values
    function _prepareMigrationData() private view returns (MigrationData memory data) {
        data.currencyAmount = auction.currencyRaised();

        data.priceX192 = auction.clearingPrice().convertToPriceX192(currency < token);
        data.sqrtPriceX96 = data.priceX192.convertToSqrtPriceX96();

        (data.tokenAmount, data.leftoverCurrency, data.initialCurrencyAmount) =
            data.priceX192.calculateAmounts(data.currencyAmount, currency < token, reserveSupply);

        data.liquidity = LiquidityAmounts.getLiquidityForAmounts(
            data.sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK / poolTickSpacing * poolTickSpacing),
            TickMath.getSqrtPriceAtTick(TickMath.MAX_TICK / poolTickSpacing * poolTickSpacing),
            currency < token ? data.currencyAmount : data.tokenAmount,
            currency < token ? data.tokenAmount : data.currencyAmount
        );

        _validateLiquidity(data.liquidity);

        data.shouldCreateOneSided =
            createOneSidedPosition && (reserveSupply > data.tokenAmount || data.leftoverCurrency > 0);

        return data;
    }

    /// @notice Validates that liquidity doesn't exceed maximum allowed per tick
    /// @param liquidity The liquidity to validate
    function _validateLiquidity(uint128 liquidity) private view {
        uint128 maxLiquidityPerTick = poolTickSpacing.tickSpacingToMaxLiquidityPerTick();

        if (liquidity > maxLiquidityPerTick) {
            revert InvalidLiquidity(maxLiquidityPerTick, liquidity);
        }
    }

    /// @notice Initializes the pool with the calculated price
    /// @param data Migration data containing the sqrt price
    /// @return key The pool key for the initialized pool
    function _initializePool(MigrationData memory data) private returns (PoolKey memory key) {
        key = PoolKey({
            currency0: Currency.wrap(currency < token ? currency : token),
            currency1: Currency.wrap(currency < token ? token : currency),
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

        if (data.shouldCreateOneSided) {
            (actions, params) = _createFullRangePositionPlan(
                data.liquidity,
                data.sqrtPriceX96,
                data.tokenAmount,
                data.initialCurrencyAmount,
                ParamsBuilder.FULL_RANGE_WITH_ONE_SIDED_SIZE
            );
            (actions, params) = _createOneSidedPositionPlan(
                actions, params, data.liquidity, data.sqrtPriceX96, data.tokenAmount, data.leftoverCurrency
            );
            data.hasOneSidedParams = params.length == ParamsBuilder.FULL_RANGE_WITH_ONE_SIDED_SIZE;
        } else {
            (actions, params) = _createFullRangePositionPlan(
                data.liquidity,
                data.sqrtPriceX96,
                data.tokenAmount,
                data.initialCurrencyAmount,
                ParamsBuilder.FULL_RANGE_SIZE
            );
            data.hasOneSidedParams = false;
        }

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
            positionManager.modifyLiquidities{value: currencyTransferAmount}(plan, block.timestamp + 1);
        } else {
            // Non-native currency: transfer first, then call modifyLiquidities
            Currency.wrap(currency).transfer(address(positionManager), currencyTransferAmount);
            positionManager.modifyLiquidities(plan, block.timestamp + 1);
        }
    }

    /// @notice Calculates the amount of tokens to transfer
    /// @param data Migration data
    /// @return The amount of tokens to transfer
    function _getTokenTransferAmount(MigrationData memory data) private view returns (uint128) {
        return (data.shouldCreateOneSided && reserveSupply > data.tokenAmount && data.hasOneSidedParams)
            ? reserveSupply
            : data.tokenAmount;
    }

    /// @notice Calculates the amount of currency to transfer
    /// @param data Migration data
    /// @return The amount of currency to transfer
    function _getCurrencyTransferAmount(MigrationData memory data) private pure returns (uint128) {
        return (data.shouldCreateOneSided && data.leftoverCurrency > 0 && data.hasOneSidedParams)
            ? data.initialCurrencyAmount + data.leftoverCurrency
            : data.initialCurrencyAmount;
    }

    function _createFullRangePositionPlan(
        uint128 liquidity,
        uint160 sqrtPriceX96,
        uint128 tokenAmount,
        uint128 currencyAmount,
        uint256 paramsArraySize
    ) private view returns (bytes memory, bytes[] memory) {
        // Create base parameters
        BasePositionParams memory baseParams = BasePositionParams({
            currency: currency,
            token: token,
            poolLPFee: poolLPFee,
            poolTickSpacing: poolTickSpacing,
            initialSqrtPriceX96: sqrtPriceX96,
            liquidity: liquidity,
            positionRecipient: positionRecipient,
            hooks: IHooks(address(this))
        });

        // Create full range specific parameters
        FullRangeParams memory fullRangeParams =
            FullRangeParams({tokenAmount: tokenAmount, currencyAmount: currencyAmount});

        // Plan the full range position
        return baseParams.planFullRangePosition(fullRangeParams, paramsArraySize);
    }

    function _createOneSidedPositionPlan(
        bytes memory actions,
        bytes[] memory params,
        uint128 existingPoolLiquidity,
        uint160 sqrtPriceX96,
        uint128 tokenAmount,
        uint128 leftoverCurrency
    ) private view returns (bytes memory, bytes[] memory) {
        uint128 amount = leftoverCurrency > 0 ? leftoverCurrency : reserveSupply - tokenAmount;
        bool inToken = leftoverCurrency == 0;

        // Create base parameters
        BasePositionParams memory baseParams = BasePositionParams({
            currency: currency,
            token: token,
            poolLPFee: poolLPFee,
            poolTickSpacing: poolTickSpacing,
            initialSqrtPriceX96: sqrtPriceX96,
            liquidity: existingPoolLiquidity,
            positionRecipient: positionRecipient,
            hooks: IHooks(address(this))
        });

        // Create one-sided specific parameters
        OneSidedParams memory oneSidedParams = OneSidedParams({amount: amount, inToken: inToken});

        // Plan the one-sided position
        return baseParams.planOneSidedPosition(oneSidedParams, actions, params);
    }

    receive() external payable {
        if (msg.sender != address(auction)) revert NotAuction(msg.sender, address(auction));
    }
}
