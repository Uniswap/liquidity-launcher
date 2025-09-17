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
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {SafeERC20} from "@openzeppelin-latest/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin-latest/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin-latest/contracts/utils/math/Math.sol";
import {IDistributionContract} from "../interfaces/IDistributionContract.sol";
import {MigratorParameters} from "../types/MigratorParams.sol";
import {ILBPStrategyBasic} from "../interfaces/ILBPStrategyBasic.sol";
import {HookBasic} from "../utils/HookBasic.sol";
import {TickCalculations} from "../libraries/TickCalculations.sol";

/// @title LBPStrategyBasic
/// @notice Basic Strategy to distribute tokens and raise funds from an auction to a v4 pool
/// @custom:security-contact security@uniswap.org
contract LBPStrategyBasic is ILBPStrategyBasic, HookBasic {
    using SafeERC20 for IERC20;
    using TickCalculations for int24;
    using CurrencyLibrary for Currency;

    /// @notice The token split is measured in mps (10_000_000 = 100%)
    uint24 public constant TOKEN_SPLIT_DENOMINATOR = 1e7;
    /// @notice The maximum token split to auction in mps (5_000_000 = 50%)
    uint24 public constant MAX_TOKEN_SPLIT_TO_AUCTION = 5e6;
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
            - uint128(uint256(_totalSupply) * uint256(migratorParams.tokenSplitToAuction) / TOKEN_SPLIT_DENOMINATOR);
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
        if (price == 0) {
            revert InvalidPrice(price);
        }
        uint128 currencyAmount = _auction.currencyRaised();

        if (Currency.wrap(currency).balanceOf(address(this)) < currencyAmount) {
            revert InsufficientCurrency(currencyAmount, uint128(Currency.wrap(currency).balanceOf(address(this)))); // would not hit this if statement if not able to fit in uint128
        }

        // inverse if currency is currency0
        if (currency < token) {
            price = FullMath.mulDiv(1 << FixedPoint96.RESOLUTION, 1 << FixedPoint96.RESOLUTION, price);
        }
        uint256 priceX192 = price << FixedPoint96.RESOLUTION; // will overflow if price > type(uint160).max
        uint160 sqrtPriceX96 = uint160(Math.sqrt(priceX192)); // price will lose precision and be rounded down
        if (sqrtPriceX96 < TickMath.MIN_SQRT_PRICE || sqrtPriceX96 > TickMath.MAX_SQRT_PRICE) {
            revert InvalidPrice(price);
        }

        // compute token amount
        uint128 tokenAmount;
        if (currency < token) {
            tokenAmount = uint128(FullMath.mulDiv(priceX192, currencyAmount, Q192));
        } else {
            tokenAmount = uint128(FullMath.mulDiv(currencyAmount, Q192, priceX192));
        }

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
            currency0: currency < token ? Currency.wrap(currency) : Currency.wrap(token),
            currency1: currency < token ? Currency.wrap(token) : Currency.wrap(currency),
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
        }
        if (migratorParams.tokenSplitToAuction > MAX_TOKEN_SPLIT_TO_AUCTION) {
            revert TokenSplitTooHigh(migratorParams.tokenSplitToAuction, MAX_TOKEN_SPLIT_TO_AUCTION);
        }
        if (
            migratorParams.poolTickSpacing > TickMath.MAX_TICK_SPACING
                || migratorParams.poolTickSpacing < TickMath.MIN_TICK_SPACING
        ) {
            revert InvalidTickSpacing(
                migratorParams.poolTickSpacing, TickMath.MIN_TICK_SPACING, TickMath.MAX_TICK_SPACING
            );
        }
        if (migratorParams.poolLPFee > LPFeeLibrary.MAX_LP_FEE) {
            revert InvalidFee(migratorParams.poolLPFee, LPFeeLibrary.MAX_LP_FEE);
        }
        if (
            migratorParams.positionRecipient == address(0)
                || migratorParams.positionRecipient == ActionConstants.MSG_SENDER
                || migratorParams.positionRecipient == ActionConstants.ADDRESS_THIS
        ) revert InvalidPositionRecipient(migratorParams.positionRecipient);
        if (uint128(uint256(_totalSupply) * uint256(migratorParams.tokenSplitToAuction) / TOKEN_SPLIT_DENOMINATOR) == 0)
        {
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
            params = new bytes[](5);
            (actions, params,) = _createFullRangePositionPlan(actions, params, sqrtPriceX96);
        } else {
            params = new bytes[](8);
            (actions, params, liquidity) = _createFullRangePositionPlan(actions, params, sqrtPriceX96);
            (actions, params) = _createOneSidedPositionPlan(actions, params, liquidity, sqrtPriceX96);
        }

        return abi.encode(actions, params);
    }

    /// @notice Creates the plan for creating a full range v4 position using the position manager
    /// @param actions The actions for the position
    /// @param params The parameters for the position
    /// @param sqrtPriceX96 The initial sqrt price of the pool
    /// @return The actions and parameters for the position
    function _createFullRangePositionPlan(bytes memory actions, bytes[] memory params, uint160 sqrtPriceX96)
        private
        view
        returns (bytes memory, bytes[] memory, uint128)
    {
        int24 minTick = TickMath.MIN_TICK / poolTickSpacing * poolTickSpacing;
        int24 maxTick = TickMath.MAX_TICK / poolTickSpacing * poolTickSpacing;
        uint128 tokenAmount = initialTokenAmount;
        uint128 currencyAmount = initialCurrencyAmount;

        PoolKey memory key = PoolKey({
            currency0: currency < token ? Currency.wrap(currency) : Currency.wrap(token),
            currency1: currency < token ? Currency.wrap(token) : Currency.wrap(currency),
            fee: poolLPFee,
            tickSpacing: poolTickSpacing,
            hooks: IHooks(address(this))
        });

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(minTick),
            TickMath.getSqrtPriceAtTick(maxTick),
            currency < token ? currencyAmount : tokenAmount,
            currency < token ? tokenAmount : currencyAmount
        );

        actions = abi.encodePacked(
            uint8(Actions.SETTLE),
            uint8(Actions.SETTLE),
            uint8(Actions.MINT_POSITION_FROM_DELTAS),
            uint8(Actions.CLEAR_OR_TAKE),
            uint8(Actions.CLEAR_OR_TAKE)
        );

        if (currency < token) {
            params[0] = abi.encode(key.currency0, currencyAmount, false);
            params[1] = abi.encode(key.currency1, tokenAmount, false);
        } else {
            params[0] = abi.encode(key.currency0, tokenAmount, false);
            params[1] = abi.encode(key.currency1, currencyAmount, false);
        }

        params[2] = abi.encode(
            key,
            minTick,
            maxTick,
            currency < token ? currencyAmount : tokenAmount,
            currency < token ? tokenAmount : currencyAmount,
            positionRecipient,
            Constants.ZERO_BYTES
        );

        params[3] = abi.encode(key.currency0, type(uint256).max);
        params[4] = abi.encode(key.currency1, type(uint256).max);

        return (actions, params, liquidity);
    }

    /// @notice Creates the plan for creating a one sided v4 position using the position manager along with the full range position
    /// @param actions The existing actions for the full range position which may be extended with the new actions for the one sided position
    /// @param params The existing parameters for the full range position which may be extended with the new parameters for the one sided position
    /// @param liquidity The existing liquidity from the full range position
    /// @param sqrtPriceX96 The initial sqrt price of the pool
    /// @return The actions and parameters needed to create the full range position and the one sided position
    function _createOneSidedPositionPlan(
        bytes memory actions,
        bytes[] memory params,
        uint128 liquidity,
        uint160 sqrtPriceX96
    ) private view returns (bytes memory, bytes[] memory) {
        // create something similar where you check if enough liquidity per tick spacing.
        // then mint the position, then settle.
        int24 initialTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        uint256 tokenAmount = reserveSupply - initialTokenAmount;
        params[5] = abi.encode(Currency.wrap(token), tokenAmount, false);

        if (currency < token) {
            // Skip position creation if initial tick is too close to lower boundary
            if (initialTick - TickMath.MIN_TICK < poolTickSpacing) {
                // truncate params to length 3
                return (actions, _truncate(params));
            }
            int24 lowerTick = TickMath.MIN_TICK / poolTickSpacing * poolTickSpacing; // Lower tick rounded to tickSpacing towards 0
            int24 upperTick = initialTick.tickFloor(poolTickSpacing); // Upper tick rounded down to nearest tick spacing multiple (or unchanged if already a multiple)

            // get liquidity
            uint128 newLiquidity = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(lowerTick),
                TickMath.getSqrtPriceAtTick(upperTick),
                0,
                tokenAmount
            );
            // check that liquidity is within limits
            if (liquidity + newLiquidity > poolTickSpacing.tickSpacingToMaxLiquidityPerTick()) {
                // truncate params to length 3
                return (actions, _truncate(params));
            }

            // Position is on the left hand side of current tick
            // For a one-sided position, we create a range from [MIN_TICK, current tick) (because upper tick is exclusive)
            // The upper tick must be a multiple of tickSpacing and exclusive
            params[6] = abi.encode(
                PoolKey({
                    currency0: Currency.wrap(currency),
                    currency1: Currency.wrap(token),
                    fee: poolLPFee,
                    tickSpacing: poolTickSpacing,
                    hooks: IHooks(address(this))
                }),
                lowerTick,
                upperTick,
                0, // No currency amount (one-sided position)
                tokenAmount, // Maximum token amount
                positionRecipient,
                Constants.ZERO_BYTES
            );
        } else {
            // Skip position creation if initial tick is too close to upper boundary
            if (TickMath.MAX_TICK - initialTick <= poolTickSpacing) {
                // truncate params to length 3
                return (actions, _truncate(params));
            }
            int24 lowerTick = initialTick.tickCeil(poolTickSpacing); // Next tick multiple above current tick
            int24 upperTick = TickMath.MAX_TICK / poolTickSpacing * poolTickSpacing; // MAX_TICK rounded to tickSpacing towards 0

            // get liquidity
            uint128 newLiquidity = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(lowerTick),
                TickMath.getSqrtPriceAtTick(upperTick),
                tokenAmount,
                0
            );
            // check that liquidity is within limits
            if (liquidity + newLiquidity > poolTickSpacing.tickSpacingToMaxLiquidityPerTick()) {
                // truncate params to length 3
                return (actions, _truncate(params));
            }

            // Position is on the right hand side of current tick
            // For a one-sided position, we create a range from (current tick, MAX_TICK) (because lower tick is inclusive)
            // The lower tick must be:
            // - A multiple of tickSpacing (inclusive)
            // - Greater than current tick
            // The upper tick must be:
            // - A multiple of tickSpacing
            params[6] = abi.encode(
                PoolKey({
                    currency0: Currency.wrap(token),
                    currency1: Currency.wrap(currency),
                    fee: poolLPFee,
                    tickSpacing: poolTickSpacing,
                    hooks: IHooks(address(this))
                }),
                lowerTick,
                upperTick,
                tokenAmount, // Maximum token amount
                0, // No currency amount (one-sided position)
                positionRecipient,
                Constants.ZERO_BYTES
            );
        }
        params[7] = abi.encode(Currency.wrap(token), type(uint256).max);
        actions = abi.encodePacked(
            actions, uint8(Actions.SETTLE), uint8(Actions.MINT_POSITION_FROM_DELTAS), uint8(Actions.CLEAR_OR_TAKE)
        );

        return (actions, params);
    }

    /// @notice Truncates the parameters to the length 5
    /// @param params The parameters to truncate
    /// @return The truncated parameters
    function _truncate(bytes[] memory params) private pure returns (bytes[] memory) {
        bytes[] memory truncated = new bytes[](5);
        truncated[0] = params[0];
        truncated[1] = params[1];
        truncated[2] = params[2];
        truncated[3] = params[3];
        truncated[4] = params[4];
        return truncated;
    }

    /// @notice Receives native currency
    receive() external payable {}
}
