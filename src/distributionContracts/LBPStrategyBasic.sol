// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IDistributionContract} from "../interfaces/IDistributionContract.sol";
import {MigratorParameters} from "../types/MigratorParams.sol";
import {ILBPStrategyBasic} from "../interfaces/ILBPStrategyBasic.sol";
import {IDistributionStrategy} from "../interfaces/IDistributionStrategy.sol";
import {HookBasic} from "../utils/HookBasic.sol";
import {ISubscriber} from "../interfaces/ISubscriber.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {console2} from "forge-std/console2.sol";

/// @title LBPStrategyBasic
/// @notice Basic Strategy to distribute tokens and raise funds from an auction to a v4 pool
contract LBPStrategyBasic is ILBPStrategyBasic, HookBasic {
    using CustomRevert for bytes4;
    using SafeERC20 for IERC20;

    /// @notice The token split is measured in bips (10_000 = 100%)
    uint16 public constant TOKEN_SPLIT_DENOMINATOR = 10_000;
    uint16 public constant MAX_TOKEN_SPLIT_TO_AUCTION = 5_000;

    address public immutable token;
    address public immutable currency;

    uint128 public immutable totalSupply;
    uint128 public immutable reserveSupply;
    address public immutable positionRecipient;
    uint64 public immutable migrationBlock;
    address public immutable auctionFactory;
    IPositionManager public immutable positionManager;

    IDistributionContract public auction;
    // The initial sqrt price for the pool, expressed as a Q64.96 fixed point number
    // This represents the square root of the ratio of currency1/currency0, where currency0 is the one with the lower address
    uint160 public initialSqrtPriceX96;
    uint128 public initialTokenAmount;
    uint128 public initialCurrencyAmount;
    PoolKey public key;
    bytes public auctionParameters;

    constructor(
        address _token,
        uint128 _totalSupply,
        MigratorParameters memory migratorParams,
        bytes memory auctionParams,
        IPositionManager _positionManager,
        IPoolManager _poolManager
    ) HookBasic(_poolManager) {
        // Validate that the amount of tokens sent to auction is <= 50% of total supply
        // This ensures at least half of the tokens remain for the initial liquidity position
        if (migratorParams.tokenSplitToAuction > MAX_TOKEN_SPLIT_TO_AUCTION) {
            revert TokenSplitTooHigh(migratorParams.tokenSplitToAuction);
        }
        if (
            migratorParams.tickSpacing > TickMath.MAX_TICK_SPACING
                || migratorParams.tickSpacing < TickMath.MIN_TICK_SPACING
        ) InvalidTickSpacing.selector.revertWith(migratorParams.tickSpacing);
        if (migratorParams.fee > LPFeeLibrary.MAX_LP_FEE) revert InvalidFee(migratorParams.fee);
        // Cannot mint a position to the zero address (not allowed by the position manager)
        // address(1) is msg.sender of the migrate action
        // address(2) is address(this)
        if (
            migratorParams.positionRecipient == address(0) || migratorParams.positionRecipient == address(1)
                || migratorParams.positionRecipient == address(2)
        ) InvalidPositionRecipient.selector.revertWith(migratorParams.positionRecipient);
        if (_token == migratorParams.currency) {
            InvalidTokenAndCurrency.selector.revertWith(_token, migratorParams.currency);
        }

        auctionParameters = auctionParams;

        token = _token;
        currency = migratorParams.currency;
        totalSupply = _totalSupply;
        // Calculate tokens reserved for liquidity by subtracting tokens allocated for auction
        // e.g. if tokenSplitToAuction = 5000 (50%), then half goes to auction and half is reserved
        // Rounds down so auction always gets less than or equal to half of the total supply
        reserveSupply = _totalSupply
            - uint128(FullMath.mulDiv(_totalSupply, migratorParams.tokenSplitToAuction, TOKEN_SPLIT_DENOMINATOR));
        positionManager = _positionManager;
        positionRecipient = migratorParams.positionRecipient;
        migrationBlock = migratorParams.migrationBlock;
        auctionFactory = migratorParams.auctionFactory;

        key = PoolKey({
            currency0: currency < token ? Currency.wrap(currency) : Currency.wrap(token),
            currency1: currency < token ? Currency.wrap(token) : Currency.wrap(currency),
            fee: migratorParams.fee,
            tickSpacing: migratorParams.tickSpacing,
            hooks: IHooks(address(this))
        });
    }

    /// @inheritdoc IDistributionContract
    function onTokensReceived() external {
        if (IERC20(token).balanceOf(address(this)) != totalSupply) {
            revert InvalidAmountReceived(totalSupply, IERC20(token).balanceOf(address(this)));
        }

        auction = IDistributionStrategy(auctionFactory).initializeDistribution(
            token, totalSupply - reserveSupply, auctionParameters, bytes32(0)
        );

        IERC20(token).safeTransfer(address(auction), totalSupply - reserveSupply);
        auction.onTokensReceived();
    }

    /// @inheritdoc ISubscriber
    function setInitialPrice(uint128 tokenAmount, uint128 currencyAmount) public payable {
        if (msg.sender != address(auction)) OnlyAuctionCanSetPrice.selector.revertWith(address(auction), msg.sender);
        if (currency == address(0)) {
            if (msg.value != currencyAmount) revert InvalidCurrencyAmount(msg.value, currencyAmount);
        } else {
            if (msg.value != 0) NonETHCurrencyCannotReceiveETH.selector.revertWith(currency);
            IERC20(currency).safeTransferFrom(msg.sender, address(this), currencyAmount);
        }
        uint256 priceX192;
        uint160 sqrtPriceX96;
        if (currency < token) {
            priceX192 = FullMath.mulDiv(tokenAmount, 2 ** 192, currencyAmount);
            sqrtPriceX96 = uint160(Math.sqrt(priceX192));
        } else {
            priceX192 = FullMath.mulDiv(currencyAmount, 2 ** 192, tokenAmount);
            sqrtPriceX96 = uint160(Math.sqrt(priceX192));
        }
        if (sqrtPriceX96 < TickMath.MIN_SQRT_PRICE || sqrtPriceX96 > TickMath.MAX_SQRT_PRICE) {
            revert InvalidPrice(sqrtPriceX96);
        }

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK / key.tickSpacing * key.tickSpacing),
            TickMath.getSqrtPriceAtTick(TickMath.MAX_TICK / key.tickSpacing * key.tickSpacing),
            currency < token ? currencyAmount : tokenAmount,
            currency < token ? tokenAmount : currencyAmount
        );

        uint128 maxLiquidityPerTick = _tickSpacingToMaxLiquidityPerTick(key.tickSpacing);

        if (liquidity > maxLiquidityPerTick) {
            revert InvalidLiquidity(maxLiquidityPerTick, liquidity);
        }

        // verify that token amounts match up with the price?

        initialSqrtPriceX96 = sqrtPriceX96;
        initialTokenAmount = tokenAmount;
        initialCurrencyAmount = currencyAmount;

        emit InitialPriceSet(initialSqrtPriceX96, tokenAmount, currencyAmount);
    }

    /// @inheritdoc ILBPStrategyBasic
    function migrate() public {
        if (block.number < migrationBlock) revert MigrationNotAllowed(migrationBlock, block.number);

        // transfer tokens to the position manager
        IERC20(token).safeTransfer(address(positionManager), reserveSupply);

        bool currencyIsNative = currency == address(0);
        // transfer raised currency to the position manager if currency is not native
        if (!currencyIsNative) {
            IERC20(currency).safeTransfer(address(positionManager), initialCurrencyAmount);
        }

        // Initialize the pool with the starting price determined by the auction
        // Will revert if:
        //      - Pool is already initialized
        //      - Initial price is not set (sqrtPriceX96 = 0)
        poolManager.initialize(key, initialSqrtPriceX96);

        (bytes memory actions, bytes[] memory params) = _createFullRangePositionPlan();
        // occurs whenever final price > initial clearing price
        if (reserveSupply > initialTokenAmount) {
            (actions, params) = _createOneSidedPositionPlan(actions, params);
        }

        bytes memory plan = abi.encode(actions, params);

        // if currency is ETH, we need to send ETH to the position manager
        if (currencyIsNative) {
            positionManager.modifyLiquidities{value: initialCurrencyAmount}(plan, block.timestamp + 1);
        } else {
            positionManager.modifyLiquidities(plan, block.timestamp + 1);
        }

        // return leftovers (wrap to weth if eth)

        emit Migrated(key, initialSqrtPriceX96);
    }

    function _createFullRangePositionPlan() internal view returns (bytes memory, bytes[] memory) {
        bytes memory actions;
        bytes[] memory params = new bytes[](3);

        actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE), uint8(Actions.SETTLE));

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            initialSqrtPriceX96,
            TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK / key.tickSpacing * key.tickSpacing),
            TickMath.getSqrtPriceAtTick(TickMath.MAX_TICK / key.tickSpacing * key.tickSpacing),
            currency < token ? initialCurrencyAmount : initialTokenAmount,
            currency < token ? initialTokenAmount : initialCurrencyAmount
        );

        params[0] = abi.encode(
            key,
            TickMath.MIN_TICK / key.tickSpacing * key.tickSpacing,
            TickMath.MAX_TICK / key.tickSpacing * key.tickSpacing,
            liquidity,
            currency < token ? initialCurrencyAmount : initialTokenAmount,
            currency < token ? initialTokenAmount : initialCurrencyAmount,
            positionRecipient,
            Constants.ZERO_BYTES
        );

        params[1] = abi.encode(Currency.wrap(currency), ActionConstants.OPEN_DELTA, false);
        params[2] = abi.encode(Currency.wrap(token), ActionConstants.OPEN_DELTA, false);

        return (actions, params);
    }

    function _createOneSidedPositionPlan(bytes memory actions, bytes[] memory params)
        internal
        view
        returns (bytes memory newActions, bytes[] memory newParams)
    {
        int24 initialTick = TickMath.getTickAtSqrtPrice(initialSqrtPriceX96);

        if (currency < token) {
            // Skip position creation if initial tick is too close to lower boundary
            if (initialTick - TickMath.MIN_TICK < key.tickSpacing) {
                return (actions, params);
            }
            (newActions, newParams) = _setUpActionsAndParams(actions, params);

            // Position is on the left hand side of current tick
            // For a one-sided position, we create a range from [MIN_TICK, current tick) (because upper tick is exclusive)
            // The upper tick must be a multiple of tickSpacing and exclusive
            newParams[4] = abi.encode(
                key,
                TickMath.MIN_TICK / key.tickSpacing * key.tickSpacing, // Lower tick rounded to tickSpacing towards 0
                _roundDownToTickSpacing(initialTick, key.tickSpacing), // Upper tick rounded down to nearest tick spacing multiple (or unchanged if already a multiple)
                0, // No currency amount (one-sided position)
                type(uint128).max, // Maximum token amount
                positionRecipient,
                Constants.ZERO_BYTES
            );
        } else {
            // Skip position creation if initial tick is too close to upper boundary
            if (TickMath.MAX_TICK - initialTick <= key.tickSpacing) {
                return (actions, params);
            }
            (newActions, newParams) = _setUpActionsAndParams(actions, params);

            // Position is on the right hand side of current tick
            // For a one-sided position, we create a range from (current tick, MAX_TICK) (because lower tick is inclusive)
            // The lower tick must be:
            // - A multiple of tickSpacing (inclusive)
            // - Greater than current tick
            // The upper tick must be:
            // - A multiple of tickSpacing
            newParams[4] = abi.encode(
                key,
                (initialTick / key.tickSpacing + 1) * key.tickSpacing, // Next tick multiple after current tick (because lower tick is inclusive)
                TickMath.MAX_TICK / key.tickSpacing * key.tickSpacing, // MAX_TICK rounded to tickSpacing towards 0
                type(uint128).max, // Maximum token amount
                0, // No currency amount (one-sided position)
                positionRecipient,
                Constants.ZERO_BYTES
            );
        }

        // take the token
        newParams[5] = abi.encode(Currency.wrap(token), positionRecipient, ActionConstants.OPEN_DELTA);

        return (newActions, newParams);
    }

    function _roundDownToTickSpacing(int24 tick, int24 tickSpacing) private pure returns (int24) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--;
        return compressed * tickSpacing;
    }

    function _setUpActionsAndParams(bytes memory actions, bytes[] memory params)
        internal
        view
        returns (bytes memory, bytes[] memory)
    {
        bytes memory newActions = abi.encodePacked(
            actions, uint8(Actions.SETTLE), uint8(Actions.MINT_POSITION_FROM_DELTAS), uint8(Actions.TAKE)
        );
        bytes[] memory newParams = new bytes[](params.length + 3);
        for (uint256 i = 0; i < params.length; i++) {
            newParams[i] = params[i];
        }
        newParams[3] = abi.encode(Currency.wrap(token), reserveSupply - initialTokenAmount, false);
        return (newActions, newParams);
    }

    /// @notice Derives max liquidity per tick from given tick spacing
    /// @dev Executed when adding liquidity
    /// @param tickSpacing The amount of required tick separation, realized in multiples of `tickSpacing`
    ///     e.g., a tickSpacing of 3 requires ticks to be initialized every 3rd tick i.e., ..., -6, -3, 0, 3, 6, ...
    /// @return result The max liquidity per tick
    function _tickSpacingToMaxLiquidityPerTick(int24 tickSpacing) internal pure returns (uint128 result) {
        // Equivalent to:
        // int24 minTick = (TickMath.MIN_TICK / tickSpacing);
        // if (TickMath.MIN_TICK  % tickSpacing != 0) minTick--;
        // int24 maxTick = (TickMath.MAX_TICK / tickSpacing);
        // uint24 numTicks = maxTick - minTick + 1;
        // return type(uint128).max / numTicks;
        int24 MAX_TICK = TickMath.MAX_TICK;
        int24 MIN_TICK = TickMath.MIN_TICK;
        // tick spacing will never be 0 since TickMath.MIN_TICK_SPACING is 1
        assembly ("memory-safe") {
            tickSpacing := signextend(2, tickSpacing)
            let minTick := sub(sdiv(MIN_TICK, tickSpacing), slt(smod(MIN_TICK, tickSpacing), 0))
            let maxTick := sdiv(MAX_TICK, tickSpacing)
            let numTicks := add(sub(maxTick, minTick), 1)
            result := div(sub(shl(128, 1), 1), numTicks)
        }
    }
}
