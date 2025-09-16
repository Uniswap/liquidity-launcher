// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAuction} from "twap-auction/src/interfaces/IAuction.sol";
import {Auction} from "twap-auction/src/Auction.sol";
import {IAuctionFactory} from "twap-auction/src/interfaces/IAuctionFactory.sol";
import {AuctionParameters} from "twap-auction/src/interfaces/IAuction.sol";
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
/// @custom:security-contact security@uniswap.org
contract LBPStrategyBasic is ILBPStrategyBasic, HookBasic {
    using SafeERC20 for IERC20;
    using TickCalculations for int24;
    using CurrencyLibrary for Currency;
    using StrategyPlanner for BasePositionParams;
    using TokenPricing for *;

    /// @notice The token split is measured in mps (10_000_000 = 100%)
    uint24 public constant MAX_TOKEN_SPLIT_TO_AUCTION = 1e7;
    /// @notice The Q192 fixed point number used for token amount calculation from priceX192
    uint256 public constant Q192 = 2 ** 192;

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
    /// @notice The position manager that will be used to create the position
    IPositionManager public immutable positionManager;

    /// @notice The auction that will be used to create the auction
    IAuction public auction;
    /// @notice The initial sqrt price for the pool, expressed as a Q64.96 fixed point number
    // This represents the square root of the ratio of currency1/currency0, where currency0 is the one with the lower address
    uint160 public initialSqrtPriceX96;
    /// @notice The initial token amount for the pool which will be used to mint liquidity for the full range position
    uint128 public initialTokenAmount;
    /// @notice The initial currency amount for the pool which will be used to mint liquidity for the full range position
    uint128 public initialCurrencyAmount;
    /// @notice The auction parameters that will be used to create the auction
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
        // e.g. if tokenSplitToAuction = 5e6 (50%), then half goes to auction and half is reserved
        // Rounds down so auction always gets less than or equal to half of the total supply
        reserveSupply = _totalSupply
            - uint128(uint256(_totalSupply) * uint256(migratorParams.tokenSplitToAuction) / MAX_TOKEN_SPLIT_TO_AUCTION);
        positionManager = _positionManager;
        positionRecipient = migratorParams.positionRecipient;
        migrationBlock = migratorParams.migrationBlock;
        auctionFactory = migratorParams.auctionFactory;

        poolLPFee = migratorParams.poolLPFee;
        poolTickSpacing = migratorParams.poolTickSpacing;
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
    function validate() external {
        IAuction _auction = auction;
        if (msg.sender != address(_auction)) revert NotAuction(msg.sender, address(_auction));

        uint256 price = _auction.clearingPrice();
        uint128 currencyAmount = _auction.currencyRaised();

        if (Currency.wrap(currency).balanceOf(address(this)) < currencyAmount) {
            revert InsufficientCurrency(currencyAmount, uint128(Currency.wrap(currency).balanceOf(address(this)))); // would not hit this if statement if not able to fit in uint128
        }

        (uint256 priceX192, uint160 sqrtPriceX96) = price.convertPrice(currency < token);

        uint128 tokenAmount = priceX192.calculateTokenAmount(currencyAmount, currency < token);

        if (tokenAmount > reserveSupply) {
            revert InvalidTokenAmount(tokenAmount, reserveSupply);
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

        emit Validated(sqrtPriceX96, tokenAmount, currencyAmount);
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

        uint160 sqrtPriceX96 = initialSqrtPriceX96;

        // Initialize the pool with the starting price determined by the auction
        // Will revert if:
        //      - Pool is already initialized
        //      - Initial price is not set (sqrtPriceX96 = 0)
        poolManager.initialize(key, sqrtPriceX96);

        bytes memory plan = _createPlan(sqrtPriceX96);

        // if currency is ETH, we need to send ETH to the position manager
        if (currencyIsNative) {
            positionManager.modifyLiquidities{value: initialCurrencyAmount}(plan, block.timestamp + 1);
        } else {
            positionManager.modifyLiquidities(plan, block.timestamp + 1);
        }

        emit Migrated(key, sqrtPriceX96);
    }

    /// @notice Validates the migrator parameters
    /// @param _token The token that is being distributed
    /// @param _totalSupply The total supply of the token that was sent to this contract to be distributed
    /// @param migratorParams The migrator parameters that will be used to create the v4 pool and position
    function _validateMigratorParams(address _token, uint128 _totalSupply, MigratorParameters memory migratorParams)
        private
        pure
    {
        if (_token == address(0) || _token == migratorParams.currency) {
            revert InvalidToken(address(_token));
        } else if (migratorParams.tokenSplitToAuction > MAX_TOKEN_SPLIT_TO_AUCTION) {
            revert TokenSplitTooHigh(migratorParams.tokenSplitToAuction, MAX_TOKEN_SPLIT_TO_AUCTION);
        } else if (
            migratorParams.poolTickSpacing > TickMath.MAX_TICK_SPACING
                || migratorParams.poolTickSpacing < TickMath.MIN_TICK_SPACING
        ) {
            revert InvalidTickSpacing(
                migratorParams.poolTickSpacing, TickMath.MIN_TICK_SPACING, TickMath.MAX_TICK_SPACING
            );
        } else if (migratorParams.poolLPFee > LPFeeLibrary.MAX_LP_FEE) {
            revert InvalidFee(migratorParams.poolLPFee, LPFeeLibrary.MAX_LP_FEE);
        } else if (
            migratorParams.positionRecipient == address(0)
                || migratorParams.positionRecipient == ActionConstants.MSG_SENDER
                || migratorParams.positionRecipient == ActionConstants.ADDRESS_THIS
        ) {
            revert InvalidPositionRecipient(migratorParams.positionRecipient);
        } else if (
            uint128(uint256(_totalSupply) * uint256(migratorParams.tokenSplitToAuction) / MAX_TOKEN_SPLIT_TO_AUCTION)
                == 0
        ) {
            revert AuctionSupplyIsZero();
        }
    }

    /// @notice Creates the plan for creating a full range and/or one sided v4 position using the position manager
    /// @param sqrtPriceX96 The initial sqrt price of the pool
    /// @return The actions and parameters for the position
    function _createPlan(uint160 sqrtPriceX96) private view returns (bytes memory) {
        bytes memory actions;
        bytes[] memory params;
        uint128 liquidity;
        if (reserveSupply == initialTokenAmount) {
            (actions, params,) = _createFullRangePositionPlan(ParamsBuilder.FULL_RANGE_SIZE, sqrtPriceX96);
        } else {
            (actions, params, liquidity) =
                _createFullRangePositionPlan(ParamsBuilder.FULL_RANGE_WITH_ONE_SIDED_SIZE, sqrtPriceX96);
            (actions, params) = _createOneSidedPositionPlan(actions, params, liquidity, sqrtPriceX96);
        }

        return abi.encode(actions, params);
    }

    /// @notice Creates the plan for creating a full range v4 position using the position manager
    /// @param sqrtPriceX96 The initial sqrt price of the pool
    /// @return The actions and parameters for the position
    function _createFullRangePositionPlan(uint256 paramsArraySize, uint160 sqrtPriceX96)
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
            initialSqrtPriceX96: sqrtPriceX96,
            positionRecipient: positionRecipient,
            hooks: IHooks(address(this))
        });

        // Create full range specific parameters
        FullRangeParams memory fullRangeParams =
            FullRangeParams({tokenAmount: initialTokenAmount, currencyAmount: initialCurrencyAmount});

        // Plan the full range position
        return baseParams.planFullRangePosition(fullRangeParams, paramsArraySize);
    }

    /// @notice Creates the plan for creating a one sided v4 position using the position manager along with the full range position
    /// @param actions The existing actions for the full range position which may be extended with the new actions for the one sided position
    /// @param params The existing parameters for the full range position which may be extended with the new parameters for the one sided position
    /// @param existingPoolLiquidity The existing liquidity from the full range position
    /// @param sqrtPriceX96 The initial sqrt price of the pool
    /// @return The actions and parameters needed to create the full range position and the one sided position
    function _createOneSidedPositionPlan(
        bytes memory actions,
        bytes[] memory params,
        uint128 existingPoolLiquidity,
        uint160 sqrtPriceX96
    ) private view returns (bytes memory, bytes[] memory) {
        // Calculate leftover token amount
        uint128 tokenAmount = reserveSupply - initialTokenAmount;

        // Create base parameters
        BasePositionParams memory baseParams = BasePositionParams({
            currency: currency,
            token: token,
            poolLPFee: poolLPFee,
            poolTickSpacing: poolTickSpacing,
            initialSqrtPriceX96: sqrtPriceX96,
            positionRecipient: positionRecipient,
            hooks: IHooks(address(this))
        });

        // Create one-sided specific parameters
        OneSidedParams memory oneSidedParams =
            OneSidedParams({tokenAmount: tokenAmount, existingPoolLiquidity: existingPoolLiquidity});

        // Plan the one-sided position
        return baseParams.planOneSidedPosition(oneSidedParams, actions, params);
    }

    /// @notice Receives native currency
    receive() external payable {}
}
