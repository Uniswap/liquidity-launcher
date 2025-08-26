// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

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
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IDistributionContract} from "../interfaces/IDistributionContract.sol";
import {MigratorParameters} from "../types/MigratorParams.sol";
import {ILBPStrategyBasic} from "../interfaces/ILBPStrategyBasic.sol";
import {IDistributionStrategy} from "../interfaces/IDistributionStrategy.sol";
import {HookBasic} from "../utils/HookBasic.sol";
import {TickCalculations} from "../libraries/TickCalculations.sol";
import {IAuction} from "twap-auction/src/interfaces/IAuction.sol";
import {Auction} from "twap-auction/src/Auction.sol";
import {AuctionParameters} from "twap-auction/src/interfaces/IAuction.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";

/// @title LBPStrategyBasic
/// @notice Basic Strategy to distribute tokens and raise funds from an auction to a v4 pool
contract LBPStrategyBasic is ILBPStrategyBasic, HookBasic {
    using SafeERC20 for IERC20;
    using TickCalculations for int24;
    using CurrencyLibrary for Currency;

    /// @notice The token split is measured in bips (10_000 = 100%)
    uint16 public constant TOKEN_SPLIT_DENOMINATOR = 10_000;
    uint16 public constant MAX_TOKEN_SPLIT_TO_AUCTION = 5_000;
    uint256 public constant Q192 = 2 ** 192; // 192 fixed point number used for token amt calculation from priceX192

    address public immutable token;
    address public immutable currency;

    uint24 public immutable poolLPFee;
    int24 public immutable poolTickSpacing;

    uint128 public immutable totalSupply;
    uint128 public immutable reserveSupply;
    address public immutable positionRecipient;
    uint64 public immutable migrationBlock;
    IPositionManager public immutable positionManager;

    IAuction public auction;
    // The initial sqrt price for the pool, expressed as a Q64.96 fixed point number
    // This represents the square root of the ratio of currency1/currency0, where currency0 is the one with the lower address
    uint160 public initialSqrtPriceX96;
    uint128 public initialTokenAmount;
    uint128 public initialCurrencyAmount;
    AuctionParameters public auctionParameters;

    constructor(
        address _token,
        uint128 _totalSupply,
        MigratorParameters memory migratorParams,
        AuctionParameters memory auctionParams,
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
        // Rounds down so auction always gets less than or equal to half of the total supply
        reserveSupply = _totalSupply
            - uint128(uint256(_totalSupply) * uint256(migratorParams.tokenSplitToAuction) / TOKEN_SPLIT_DENOMINATOR);
        positionManager = _positionManager;
        positionRecipient = migratorParams.positionRecipient;
        migrationBlock = migratorParams.migrationBlock;

        poolLPFee = migratorParams.poolLPFee;
        poolTickSpacing = migratorParams.poolTickSpacing;
    }

    /// @inheritdoc IDistributionContract
    function onTokensReceived() external {
        if (IERC20(token).balanceOf(address(this)) < totalSupply) {
            revert InvalidAmountReceived(totalSupply, IERC20(token).balanceOf(address(this)));
        }

        uint128 auctionSupply = totalSupply - reserveSupply;

        auction = IAuction((address(new Auction{salt: bytes32(0)}(token, auctionSupply, auctionParameters))));

        Currency.wrap(token).transfer(address(auction), auctionSupply);
        auction.onTokensReceived();
    }

    /// @inheritdoc ILBPStrategyBasic
    function fetchPriceAndCurrencyFromAuction() external {
        if (block.number < auction.endBlock()) revert AuctionNotEnded(auction.endBlock(), block.number);
        uint256 price = auction.clearingPrice();
        if (price == 0) {
            revert InvalidPrice(price);
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

        uint128 currencyAmount = uint128(Currency.wrap(currency).balanceOf(address(this)));
        auction.sweepCurrency();
        currencyAmount = uint128(Currency.wrap(currency).balanceOf(address(this)) - currencyAmount);

        // compute token amount
        // will revert if cannot fit in uint128
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

        // Initialize the pool with the starting price determined by the auction
        // Will revert if:
        //      - Pool is already initialized
        //      - Initial price is not set (sqrtPriceX96 = 0)
        poolManager.initialize(key, initialSqrtPriceX96);

        bytes memory plan = _createPlan();

        // if currency is ETH, we need to send ETH to the position manager
        if (currencyIsNative) {
            positionManager.modifyLiquidities{value: initialCurrencyAmount}(plan, block.timestamp + 1);
        } else {
            positionManager.modifyLiquidities(plan, block.timestamp + 1);
        }

        emit Migrated(key, initialSqrtPriceX96);
    }

    function _validateMigratorParams(address _token, uint128 _totalSupply, MigratorParameters memory migratorParams)
        private
        pure
    {
        // Validate that the amount of tokens sent to auction is <= 50% of total supply
        // This ensures at least half of the tokens remain for the initial liquidity position
        if (migratorParams.tokenSplitToAuction > MAX_TOKEN_SPLIT_TO_AUCTION) {
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
        if (uint128(uint256(_totalSupply) * uint256(migratorParams.tokenSplitToAuction) / TOKEN_SPLIT_DENOMINATOR) == 0)
        {
            revert AuctionSupplyIsZero();
        }
    }

    function _createPlan() private view returns (bytes memory) {
        bytes memory actions;
        bytes[] memory params;
        uint128 liquidity;
        if (reserveSupply == initialTokenAmount) {
            params = new bytes[](5);
            (actions, params,) = _createFullRangePositionPlan(actions, params);
        } else {
            params = new bytes[](8);
            (actions, params, liquidity) = _createFullRangePositionPlan(actions, params);
            (actions, params) = _createOneSidedPositionPlan(actions, params, liquidity);
        }

        return abi.encode(actions, params);
    }

    function _createFullRangePositionPlan(bytes memory actions, bytes[] memory params)
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
            initialSqrtPriceX96,
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

    function _createOneSidedPositionPlan(bytes memory actions, bytes[] memory params, uint128 liquidity)
        private
        view
        returns (bytes memory, bytes[] memory)
    {
        // create something similar where you check if enough liquidity per tick spacing.
        // then mint the position, then settle.
        int24 initialTick = TickMath.getTickAtSqrtPrice(initialSqrtPriceX96);
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
                initialSqrtPriceX96,
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
                initialSqrtPriceX96,
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

    function _truncate(bytes[] memory params) private pure returns (bytes[] memory) {
        bytes[] memory truncated = new bytes[](5);
        truncated[0] = params[0];
        truncated[1] = params[1];
        truncated[2] = params[2];
        truncated[3] = params[3];
        truncated[4] = params[4];
        return truncated;
    }

    receive() external payable {}
}
