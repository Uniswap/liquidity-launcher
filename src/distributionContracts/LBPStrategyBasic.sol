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
/// @custom:security-contact security@uniswap.org
contract LBPStrategyBasic is ILBPStrategyBasic, HookBasic {
    using SafeERC20 for IERC20;
    using TickCalculations for int24;
    using CurrencyLibrary for Currency;
    using StrategyPlanner for BasePositionParams;
    using TokenPricing for *;

    /// @notice The maximum percentage of the supply for distribution that can be sent to the auction, expressed in mps (1e7 = 100%)
    uint24 public constant MAX_TOKEN_SPLIT = 1e7;

    /// @notice The token that is being distributed
    address public immutable token;
    /// @notice The currency that the auction raised funds in
    address public immutable currency;

    /// @notice The LP fee that the v4 pool will use
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
        _validateAuctionParams(_auctionParams);

        auctionParameters = _auctionParams;

        token = _token;
        currency = _migratorParams.currency;
        totalSupply = _totalSupply;
        // Calculate tokens reserved for liquidity by subtracting tokens allocated for auction
        // e.g. if tokenSplitToAuction = 5e6 (50%), then half goes to auction and half is reserved
        reserveSupply = _totalSupply
            - uint128(uint256(_totalSupply) * uint256(_migratorParams.tokenSplitToAuction) / MAX_TOKEN_SPLIT);
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

    /// @inheritdoc IDistributionContract
    function onTokensReceived() external {
        if (IERC20(token).balanceOf(address(this)) < totalSupply) {
            revert InvalidAmountReceived(totalSupply, IERC20(token).balanceOf(address(this)));
        }

        uint128 auctionSupply = totalSupply - reserveSupply;

        IAuction _auction = IAuction(
            address(
                IAuctionFactory(auctionFactory).initializeDistribution(
                    token, auctionSupply, auctionParameters, bytes32(0)
                )
            )
        );

        Currency.wrap(token).transfer(address(_auction), auctionSupply);
        _auction.onTokensReceived();
        auction = _auction;

        emit AuctionCreated(address(_auction));
    }

    /// @inheritdoc ILBPStrategyBasic
    function migrate() external {
        if (block.number < migrationBlock) revert MigrationNotAllowed(migrationBlock, block.number);

        uint128 currencyAmount = auction.currencyRaised();

        if (Currency.wrap(currency).balanceOf(address(this)) < currencyAmount) {
            // currency was not sent over from auction (either because auction failed or because it was not sent over yet)
            revert InsufficientCurrency(currencyAmount, uint128(Currency.wrap(currency).balanceOf(address(this)))); // would not hit this if statement if not able to fit in uint128
        }

        (uint256 priceX192, uint160 sqrtPriceX96) = auction.clearingPrice().convertPrice(currency < token);

        (uint128 tokenAmount, uint128 leftoverCurrency, uint128 initialCurrencyAmount) =
            priceX192.calculateAmounts(currencyAmount, currency < token, reserveSupply);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK / poolTickSpacing * poolTickSpacing),
            TickMath.getSqrtPriceAtTick(TickMath.MAX_TICK / poolTickSpacing * poolTickSpacing),
            currency < token ? initialCurrencyAmount : tokenAmount,
            currency < token ? tokenAmount : initialCurrencyAmount
        );

        uint128 maxLiquidityPerTick = poolTickSpacing.tickSpacingToMaxLiquidityPerTick();

        if (liquidity > maxLiquidityPerTick) {
            revert InvalidLiquidity(maxLiquidityPerTick, liquidity);
        }

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
        poolManager.initialize(key, sqrtPriceX96);

        bytes memory actions;
        bytes[] memory params;

        // Determine if we should create a one-sided position in tokens if createOneSidedTokenPosition is set OR
        // if we should create a one-sided position in currency if createOneSidedCurrencyPosition is set and there is leftover currency
        bool shouldCreateOneSided = createOneSidedTokenPosition && reserveSupply > tokenAmount
            || createOneSidedCurrencyPosition && leftoverCurrency > 0;

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

        if (shouldCreateOneSided) {
            (actions, params) = _createFullRangePositionPlan(
                baseParams, tokenAmount, initialCurrencyAmount, ParamsBuilder.FULL_RANGE_WITH_ONE_SIDED_SIZE
            );
            (actions, params) = _createOneSidedPositionPlan(baseParams, actions, params, tokenAmount, leftoverCurrency);
        } else {
            (actions, params) = _createFullRangePositionPlan(
                baseParams, tokenAmount, initialCurrencyAmount, ParamsBuilder.FULL_RANGE_SIZE
            );
        }

        bytes memory plan = abi.encode(actions, params);

        // if currency is ETH, we need to send ETH to the position manager
        if (currencyIsNative) {
            positionManager.modifyLiquidities{value: initialCurrencyAmount + leftoverCurrency}(
                plan, block.timestamp + 1
            );
        } else {
            positionManager.modifyLiquidities(plan, block.timestamp + 1);
        }

        emit Migrated(key, sqrtPriceX96);
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

    /// @notice Validates the migrator parameters
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
        // token split validation (cannot be greater than 100%)
        else if (migratorParams.tokenSplitToAuction > MAX_TOKEN_SPLIT) {
            revert TokenSplitTooHigh(migratorParams.tokenSplitToAuction, MAX_TOKEN_SPLIT);
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
        else if (uint128(uint256(_totalSupply) * uint256(migratorParams.tokenSplitToAuction) / MAX_TOKEN_SPLIT) == 0) {
            revert AuctionSupplyIsZero();
        }
    }

    /// @notice Validates that the funds recipient in the auction parameters is set to ActionConstants.MSG_SENDER (address(1)),
    ///         which will be replaced with this contract's address by the AuctionFactory during auction creation
    /// @dev Will revert if the parameters are not correcly encoded for AuctionParameters
    /// @param auctionParams The auction parameters that will be used to create the auction
    function _validateAuctionParams(bytes memory auctionParams) private pure {
        AuctionParameters memory parameters = abi.decode(auctionParams, (AuctionParameters));
        if (parameters.fundsRecipient != ActionConstants.MSG_SENDER) {
            revert InvalidFundsRecipient(parameters.fundsRecipient, ActionConstants.MSG_SENDER);
        }
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
        uint128 amount = leftoverCurrency > 0 ? leftoverCurrency : reserveSupply - tokenAmount;
        bool inToken = leftoverCurrency == 0;

        // Create one-sided specific parameters
        OneSidedParams memory oneSidedParams = OneSidedParams({amount: amount, inToken: inToken});

        // Plan the one-sided position
        return baseParams.planOneSidedPosition(oneSidedParams, actions, params);
    }

    /// @notice Receives native currency only from the auction
    receive() external payable {
        if (msg.sender != address(auction)) revert NotAuction(msg.sender, address(auction));
    }
}
