// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ContinuousClearingAuction} from "continuous-clearing-auction/src/ContinuousClearingAuction.sol";
import {
    AuctionParameters,
    IContinuousClearingAuction
} from "continuous-clearing-auction/src/interfaces/IContinuousClearingAuction.sol";
import {
    IContinuousClearingAuctionFactory
} from "continuous-clearing-auction/src/interfaces/IContinuousClearingAuctionFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SelfInitializerHook} from "periphery/hooks/SelfInitializerHook.sol";
import {IDistributionContract} from "../../interfaces/IDistributionContract.sol";
import {ILBPStrategyBase} from "../../interfaces/ILBPStrategyBase.sol";
import {MigrationData} from "../../types/MigrationData.sol";
import {MigratorParameters} from "../../types/MigratorParameters.sol";
import {BasePositionParams, FullRangeParams, OneSidedParams} from "../../types/PositionTypes.sol";
import {ParamsBuilder} from "../../libraries/ParamsBuilder.sol";
import {StrategyPlanner} from "../../libraries/StrategyPlanner.sol";
import {TokenDistribution} from "../../libraries/TokenDistribution.sol";
import {TokenPricing} from "../../libraries/TokenPricing.sol";

/// @title LBPStrategyBase
/// @notice Base contract for derived LBPStrategies
/// @custom:security-contact security@uniswap.org
abstract contract LBPStrategyBase is ILBPStrategyBase, SelfInitializerHook {
    using CurrencyLibrary for Currency;
    using StrategyPlanner for BasePositionParams;
    using TokenDistribution for uint128;
    using TokenPricing for uint256;

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
    /// @notice The maximum amount of currency that can be used to mint the initial liquidity position in the v4 pool
    uint128 public immutable maxCurrencyAmountForLP;
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
    /// @notice The position manager that will be used to create the position
    IPositionManager public immutable positionManager;

    /// @notice The auction contract
    IContinuousClearingAuction public auction;
    /// @notice The auction parameters used to initialize the auction via the factory
    bytes public auctionParameters;

    constructor(
        address _token,
        uint128 _totalSupply,
        MigratorParameters memory _migratorParams,
        bytes memory _auctionParams,
        IPositionManager _positionManager,
        IPoolManager _poolManager
    ) SelfInitializerHook(_poolManager) {
        _validateMigratorParams(_totalSupply, _migratorParams);
        _validateAuctionParams(_auctionParams, _migratorParams);

        auctionParameters = _auctionParams;

        token = _token;
        currency = _migratorParams.currency;
        totalSupply = _totalSupply;
        // Calculate tokens reserved for liquidity by subtracting tokens allocated for auction
        //   e.g. if tokenSplitToAuction = 5e6 (50%), then half goes to auction and half is reserved
        reserveSupply = _totalSupply.calculateReserveSupply(_migratorParams.tokenSplitToAuction);
        maxCurrencyAmountForLP = _migratorParams.maxCurrencyAmountForLP;
        positionManager = _positionManager;
        positionRecipient = _migratorParams.positionRecipient;
        migrationBlock = _migratorParams.migrationBlock;
        auctionFactory = _migratorParams.auctionFactory;
        poolLPFee = _migratorParams.poolLPFee;
        poolTickSpacing = _migratorParams.poolTickSpacing;
        operator = _migratorParams.operator;
        sweepBlock = _migratorParams.sweepBlock;
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

        IContinuousClearingAuction _auction = IContinuousClearingAuction(
            address(
                IContinuousClearingAuctionFactory(auctionFactory)
                    .initializeDistribution(token, auctionSupply, auctionParameters, bytes32(0))
            )
        );

        Currency.wrap(token).transfer(address(_auction), auctionSupply);
        _auction.onTokensReceived();
        auction = _auction;

        emit AuctionCreated(address(_auction));
    }

    /// @inheritdoc ILBPStrategyBase
    function migrate() external {
        _validateMigration();

        MigrationData memory data = _prepareMigrationData();

        PoolKey memory key = _initializePool(data);

        bytes memory plan = _createPositionPlan(data);

        _transferAssetsAndExecutePlan(_getTokenTransferAmount(data), _getCurrencyTransferAmount(data), plan);

        emit Migrated(key, data.sqrtPriceX96);
    }

    /// @inheritdoc ILBPStrategyBase
    function sweepToken() external {
        if (block.number < sweepBlock) revert SweepNotAllowed(sweepBlock, block.number);
        if (msg.sender != operator) revert NotOperator(msg.sender, operator);

        uint256 tokenBalance = Currency.wrap(token).balanceOf(address(this));
        if (tokenBalance > 0) {
            Currency.wrap(token).transfer(operator, tokenBalance);
            emit TokensSwept(operator, tokenBalance);
        }
    }

    /// @inheritdoc ILBPStrategyBase
    function sweepCurrency() external {
        if (block.number < sweepBlock) revert SweepNotAllowed(sweepBlock, block.number);
        if (msg.sender != operator) revert NotOperator(msg.sender, operator);

        uint256 currencyBalance = Currency.wrap(currency).balanceOf(address(this));
        if (currencyBalance > 0) {
            Currency.wrap(currency).transfer(operator, currencyBalance);
            emit CurrencySwept(operator, currencyBalance);
        }
    }

    /// @notice Get the currency0 of the pool
    function _currency0() internal view returns (Currency) {
        return Currency.wrap(_currencyIsCurrency0() ? currency : getPoolToken());
    }

    /// @notice Get the currency1 of the pool
    function _currency1() internal view returns (Currency) {
        return Currency.wrap(_currencyIsCurrency0() ? getPoolToken() : currency);
    }

    /// @notice Returns true if the currency is currency0 of the pool
    function _currencyIsCurrency0() internal view returns (bool) {
        return currency < getPoolToken();
    }

    /// @notice Validates the migrator parameters and reverts if any are invalid. Continues if all are valid
    /// @param _totalSupply The total supply of the token that was sent to this contract to be distributed
    /// @param migratorParams The migrator parameters that will be used to create the v4 pool and position
    function _validateMigratorParams(uint128 _totalSupply, MigratorParameters memory migratorParams) private pure {
        // sweep block validation (cannot be before or equal to the migration block)
        if (migratorParams.sweepBlock <= migratorParams.migrationBlock) {
            revert InvalidSweepBlock(migratorParams.sweepBlock, migratorParams.migrationBlock);
        }
        // token split validation (cannot be greater than or equal to 100%)
        else if (migratorParams.tokenSplitToAuction >= TokenDistribution.MAX_TOKEN_SPLIT) {
            revert TokenSplitTooHigh(migratorParams.tokenSplitToAuction, TokenDistribution.MAX_TOKEN_SPLIT);
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

    /// @notice Validates that the auction parameters are valid
    /// @dev Ensures that the `fundsRecipient` is set to ActionConstants.MSG_SENDER
    ///      and that the auction concludes before the configured migration block.
    /// @param auctionParams The auction parameters that will be used to create the auction
    /// @param migratorParams The migrator parameters that will be used to create the v4 pool and position
    function _validateAuctionParams(bytes memory auctionParams, MigratorParameters memory migratorParams) private pure {
        AuctionParameters memory _auctionParams = abi.decode(auctionParams, (AuctionParameters));
        if (_auctionParams.fundsRecipient != ActionConstants.MSG_SENDER) {
            revert InvalidFundsRecipient(_auctionParams.fundsRecipient, ActionConstants.MSG_SENDER);
        } else if (_auctionParams.endBlock >= migratorParams.migrationBlock) {
            revert InvalidEndBlock(_auctionParams.endBlock, migratorParams.migrationBlock);
        } else if (_auctionParams.currency != migratorParams.currency) {
            revert InvalidCurrency(_auctionParams.currency, migratorParams.currency);
        }
    }

    /// @notice Validates migration timing and currency balance
    function _validateMigration() private {
        if (block.number < migrationBlock) {
            revert MigrationNotAllowed(migrationBlock, block.number);
        }

        // call checkpoint to get the final currency raised and clearing price
        auction.checkpoint();
        uint256 currencyAmount = auction.currencyRaised();

        // cannot create a v4 pool with more than type(uint128).max currency amount
        if (currencyAmount > type(uint128).max) {
            revert CurrencyAmountTooHigh(currencyAmount, type(uint128).max);
        }

        // cannot create a v4 pool with no currency raised
        if (currencyAmount == 0) {
            revert NoCurrencyRaised();
        }

        if (Currency.wrap(currency).balanceOf(address(this)) < currencyAmount) {
            revert InsufficientCurrency(currencyAmount, Currency.wrap(currency).balanceOf(address(this)));
        }
    }

    /// @notice Prepares all migration data including prices, amounts, and liquidity calculations
    /// @return data MigrationData struct containing all calculated values
    function _prepareMigrationData() internal view returns (MigrationData memory) {
        // Both currencyRaised and maxCurrencyAmountForLP are validated to be less than or equal to type(uint128).max
        uint128 currencyAmount = uint128(FixedPointMathLib.min(auction.currencyRaised(), maxCurrencyAmountForLP));
        bool currencyIsCurrency0 = _currencyIsCurrency0();

        uint256 priceX192 = auction.clearingPrice().convertToPriceX192(currencyIsCurrency0);
        uint160 sqrtPriceX96 = priceX192.convertToSqrtPriceX96();

        (uint128 initialTokenAmount, uint128 initialCurrencyAmount) =
            priceX192.calculateAmounts(currencyAmount, currencyIsCurrency0, reserveSupply);

        uint128 leftoverCurrency = currencyAmount - initialCurrencyAmount;

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(poolTickSpacing)),
            TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(poolTickSpacing)),
            currencyIsCurrency0 ? initialCurrencyAmount : initialTokenAmount,
            currencyIsCurrency0 ? initialTokenAmount : initialCurrencyAmount
        );

        return MigrationData({
            sqrtPriceX96: sqrtPriceX96,
            initialTokenAmount: initialTokenAmount,
            initialCurrencyAmount: initialCurrencyAmount,
            leftoverCurrency: leftoverCurrency,
            liquidity: liquidity
        });
    }

    /// @notice Initializes the pool with the calculated price
    /// @param data Migration data containing the sqrt price
    /// @return key The pool key for the initialized pool
    function _initializePool(MigrationData memory data) private returns (PoolKey memory key) {
        key = PoolKey({
            currency0: _currency0(),
            currency1: _currency1(),
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

    /// @notice Transfers assets to position manager and executes the position plan
    /// @param tokenTransferAmount The amount of tokens to transfer to the position manager
    /// @param currencyTransferAmount The amount of currency to transfer to the position manager
    /// @param plan The encoded position plan to execute
    function _transferAssetsAndExecutePlan(
        uint128 tokenTransferAmount,
        uint128 currencyTransferAmount,
        bytes memory plan
    ) private {
        // Transfer tokens to position manager
        Currency.wrap(token).transfer(address(positionManager), tokenTransferAmount);
        if (Currency.wrap(currency).isAddressZero()) {
            // Native currency: send as value with modifyLiquidities call
            positionManager.modifyLiquidities{value: currencyTransferAmount}(plan, block.timestamp);
        } else {
            // Non-native currency: transfer first, then call modifyLiquidities
            Currency.wrap(currency).transfer(address(positionManager), currencyTransferAmount);
            positionManager.modifyLiquidities(plan, block.timestamp);
        }
    }

    /// @notice Creates the position plan based on migration data
    /// @param data Migration data with all necessary parameters
    /// @return plan The encoded position plan
    function _createPositionPlan(MigrationData memory data) internal virtual returns (bytes memory plan);

    /// @notice Calculates the amount of tokens to transfer
    /// @param data Migration data
    /// @return The amount of tokens to transfer to the position manager
    function _getTokenTransferAmount(MigrationData memory data) internal view virtual returns (uint128);

    /// @notice Calculates the amount of currency to transfer
    /// @param data Migration data
    /// @return The amount of currency to transfer to the position manager
    function _getCurrencyTransferAmount(MigrationData memory data) internal view virtual returns (uint128);

    /// @notice Receives native currency
    receive() external payable {}
}
