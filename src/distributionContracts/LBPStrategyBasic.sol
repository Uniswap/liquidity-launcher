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
    IPositionManager public immutable positionManager;

    IAuction public auction;
    // The initial sqrt price for the pool, expressed as a Q64.96 fixed point number
    // This represents the square root of the ratio of currency1/currency0, where currency0 is the one with the lower address
    uint160 public initialSqrtPriceX96;
    uint128 public initialTokenAmount;
    uint128 public initialCurrencyAmount;
    uint128 public leftoverCurrency;
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
    function validate() external {
        if (msg.sender != address(auction)) revert NotAuction(msg.sender, address(auction));

        uint256 price = auction.clearingPrice();
        uint128 currencyAmount = auction.currencyRaised();

        if (Currency.wrap(currency).balanceOf(address(this)) < currencyAmount) {
            revert InsufficientCurrency(currencyAmount, uint128(Currency.wrap(currency).balanceOf(address(this)))); // would not hit this if statement if not able to fit in uint128
        }

        (uint256 priceX192, uint160 sqrtPriceX96) = price.convertPrice(currency < token);

        (uint128 tokenAmount, uint128 remainingCurrency, uint128 correspondingCurrencyAmount) =
            priceX192.calculateAmounts(currencyAmount, currency < token, reserveSupply);

        if (remainingCurrency > 0) {
            leftoverCurrency = remainingCurrency;
            currencyAmount = correspondingCurrencyAmount;
        }

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK / poolTickSpacing * poolTickSpacing),
            TickMath.getSqrtPriceAtTick(TickMath.MAX_TICK / poolTickSpacing * poolTickSpacing),
            currency < token ? currencyAmount : tokenAmount,
            currency < token ? tokenAmount : currencyAmount
        );

        uint128 maxLiquidityPerTick = poolTickSpacing.tickSpacingToMaxLiquidityPerTick();

        if (liquidity > maxLiquidityPerTick) {
            revert InvalidLiquidity(maxLiquidityPerTick, liquidity);
        }

        initialSqrtPriceX96 = sqrtPriceX96;
        initialTokenAmount = tokenAmount;
        initialCurrencyAmount = currencyAmount;
    }

    /// @inheritdoc ILBPStrategyBasic
    function migrate() external {
        if (block.number < migrationBlock) revert MigrationNotAllowed(migrationBlock, block.number);

        // transfer tokens to the position manager
        Currency.wrap(token).transfer(address(positionManager), reserveSupply);

        bool currencyIsNative = Currency.wrap(currency).isAddressZero();
        // transfer raised currency to the position manager if currency is not native
        if (!currencyIsNative) {
            Currency.wrap(currency).transfer(address(positionManager), initialCurrencyAmount);
        }

        PoolKey memory key = PoolKey({
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
        poolManager.initialize(key, initialSqrtPriceX96);

        bytes memory plan = _createPlan();

        // if currency is ETH, we need to send ETH to the position manager
        if (currencyIsNative) {
            positionManager.modifyLiquidities{value: initialCurrencyAmount + leftoverCurrency}(
                plan, block.timestamp + 1
            );
        } else {
            positionManager.modifyLiquidities(plan, block.timestamp + 1);
        }

        emit Migrated(key, initialSqrtPriceX96);
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

    function _createPlan() private view returns (bytes memory) {
        bytes memory actions;
        bytes[] memory params;
        uint128 liquidity;
        if (reserveSupply == initialTokenAmount) {
            if (leftoverCurrency > 0) {
                (actions, params, liquidity) =
                    _createFullRangePositionPlan(ParamsBuilder.FULL_RANGE_WITH_ONE_SIDED_PARAMS);
                (actions, params) = _createOneSidedPositionPlan(actions, params, liquidity);
            } else {
                (actions, params,) = _createFullRangePositionPlan(ParamsBuilder.FULL_RANGE_ONLY_PARAMS);
            }
        } else {
            (actions, params, liquidity) = _createFullRangePositionPlan(ParamsBuilder.FULL_RANGE_WITH_ONE_SIDED_PARAMS);
            (actions, params) = _createOneSidedPositionPlan(actions, params, liquidity);
        }

        return abi.encode(actions, params);
    }

    function _createFullRangePositionPlan(uint256 paramsArraySize)
        private
        view
        returns (bytes memory, bytes[] memory, uint128)
    {
        // Create base parameters
        BasePositionParams memory baseParams = BasePositionParams({
            currency: currency,
            token: token,
            poolLPFee: poolLPFee,
            poolTickSpacing: poolTickSpacing,
            initialSqrtPriceX96: initialSqrtPriceX96,
            positionRecipient: positionRecipient,
            hooks: IHooks(address(this))
        });

        // Create full range specific parameters
        FullRangeParams memory fullRangeParams =
            FullRangeParams({tokenAmount: initialTokenAmount, currencyAmount: initialCurrencyAmount});

        // Plan the full range position
        return baseParams.planFullRangePosition(fullRangeParams, paramsArraySize);
    }

    function _createOneSidedPositionPlan(bytes memory actions, bytes[] memory params, uint128 existingPoolLiquidity)
        private
        view
        returns (bytes memory, bytes[] memory)
    {
        uint128 amount = leftoverCurrency > 0 ? leftoverCurrency : reserveSupply - initialTokenAmount;
        bool inToken = leftoverCurrency == 0;

        // Create base parameters
        BasePositionParams memory baseParams = BasePositionParams({
            currency: currency,
            token: token,
            poolLPFee: poolLPFee,
            poolTickSpacing: poolTickSpacing,
            initialSqrtPriceX96: initialSqrtPriceX96,
            positionRecipient: positionRecipient,
            hooks: IHooks(address(this))
        });

        // Create one-sided specific parameters
        OneSidedParams memory oneSidedParams =
            OneSidedParams({amount: amount, existingPoolLiquidity: existingPoolLiquidity, inToken: inToken});

        // Plan the one-sided position
        return baseParams.planOneSidedPosition(oneSidedParams, actions, params);
    }

    receive() external payable {}
}
