// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IDistributionContract} from "../interfaces/IDistributionContract.sol";
import {MigratorParameters} from "../types/MigratorParams.sol";
import {ILBPStrategyBasic} from "../interfaces/ILBPStrategyBasic.sol";
import {IDistributionStrategy} from "../interfaces/IDistributionStrategy.sol";
import {HookBasic} from "../utils/HookBasic.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

/// @title LBPStrategyBasic
/// @notice Basic Strategy to distribute tokens and raise funds from an auction to a v4 pool
contract LBPStrategyBasic is ILBPStrategyBasic, HookBasic {
    using CustomRevert for bytes4;
    using SafeERC20 for IERC20;

    /// @notice The token split is measured in bips (10_000 = 100%)
    uint16 public constant TOKEN_SPLIT_DENOMINATOR = 10_000;
    uint16 public constant MAX_TOKEN_SPLIT_TO_AUCTION = 5000;

    address public immutable token;
    address public immutable currency;

    uint256 public immutable totalSupply;
    uint256 public immutable reserveSupply;
    address public immutable positionRecipient;
    uint64 public immutable migrationBlock;
    address public immutable auctionFactory;
    IPositionManager public immutable positionManager;

    IDistributionContract public auction;
    uint160 public initialSqrtPriceX96; // expressed as currency1/currency0
    uint256 public initialTokenAmount;
    uint256 public initialCurrencyAmount;
    PoolKey public key;
    bytes public auctionParameters;

    constructor(
        address _token,
        uint256 _totalSupply,
        MigratorParameters memory migratorParams,
        bytes memory auctionParams
    ) HookBasic(migratorParams) {
        // validate token split is less than or equal to 50%
        if (migratorParams.tokenSplitToAuction > MAX_TOKEN_SPLIT_TO_AUCTION) TokenSplitTooHigh.selector.revertWith();
        // these would prevent liquidity from being migrated
        if (
            migratorParams.tickSpacing > TickMath.MAX_TICK_SPACING
                || migratorParams.tickSpacing < TickMath.MIN_TICK_SPACING
        ) InvalidTickSpacing.selector.revertWith();
        if (migratorParams.fee > LPFeeLibrary.MAX_LP_FEE) InvalidFee.selector.revertWith();
        // cannot mint a position to the zero address (not allowed by the position manager)
        // address(1) is msg.sender of the migrate action, address(2) is address(this)
        // if position recipient is a contract, it may need to accept ETH
        if (
            migratorParams.positionRecipient == address(0) || migratorParams.positionRecipient == address(1)
                || migratorParams.positionRecipient == address(2)
        ) InvalidPositionRecipient.selector.revertWith();
        if (_token == migratorParams.currency) InvalidTokenAndCurrency.selector.revertWith();

        // if there is a mistake that occurs, tokens can get trapped in auction contract.
        if (migratorParams.positionManager == address(0)) InvalidPositionManager.selector.revertWith();
        if (migratorParams.poolManager == address(0)) InvalidPoolManager.selector.revertWith();

        auctionParameters = auctionParams;

        token = _token;
        currency = migratorParams.currency;
        totalSupply = _totalSupply;
        reserveSupply = _totalSupply - (_totalSupply * migratorParams.tokenSplitToAuction / TOKEN_SPLIT_DENOMINATOR);
        positionManager = IPositionManager(migratorParams.positionManager);
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
        if (IERC20(token).balanceOf(address(this)) != totalSupply) InvalidAmountReceived.selector.revertWith();

        auction = IDistributionStrategy(auctionFactory).initializeDistribution(
            token, reserveSupply, auctionParameters, bytes32(0)
        );

        IERC20(token).safeTransfer(address(auction), reserveSupply);
        auction.onTokensReceived();
    }

    /// @inheritdoc ILBPStrategyBasic
    /// @dev The sqrt price is always expressed as currency1/currency0, where currency0 < currency1
    function setInitialPrice(uint160 sqrtPriceX96, uint256 tokenAmount, uint256 currencyAmount) public payable {
        if (msg.sender != address(auction)) OnlyAuctionCanSetPrice.selector.revertWith();
        // auction should ensure price is not less than min or greater than max. If it is, it will not be able to migrate.
        if (Currency.wrap(currency).isAddressZero()) {
            if (msg.value != currencyAmount) InvalidCurrencyAmount.selector.revertWith();
        } else {
            if (msg.value != 0) NonETHCurrencyCannotReceiveETH.selector.revertWith();
            IERC20(currency).safeTransferFrom(msg.sender, address(this), currencyAmount);
        }
        initialSqrtPriceX96 = sqrtPriceX96;
        initialTokenAmount = tokenAmount;
        initialCurrencyAmount = currencyAmount;

        emit InitialPriceSet(sqrtPriceX96, tokenAmount, currencyAmount);
    }

    /// @inheritdoc ILBPStrategyBasic
    function migrate() public {
        if (block.number < migrationBlock) MigrationNotAllowed.selector.revertWith();

        // transfer tokens to the position manager
        IERC20(token).safeTransfer(address(positionManager), reserveSupply);

        bool currencyIsNative = Currency.wrap(currency).isAddressZero();
        // transfer raised currency to the position manager if currency is not ETH
        if (!currencyIsNative) {
            IERC20(currency).safeTransfer(address(positionManager), initialCurrencyAmount);
        }

        // initialize pool with starting price
        // fails if already initialized or if the price is not set / is 0 (MIN_SQRT_PRICE is 4295128739)
        poolManager.initialize(key, initialSqrtPriceX96);

        (bytes memory plan, bytes memory newPlan) = _createPlan();

        // if currency is ETH, we need to send ETH to the position manager
        if (currencyIsNative) {
            positionManager.modifyLiquidities{value: initialCurrencyAmount}(plan, block.timestamp + 1);
        } else {
            positionManager.modifyLiquidities(plan, block.timestamp + 1);
        }

        if (newPlan.length > 0) {
            positionManager.modifyLiquidities(newPlan, block.timestamp + 1);
        }

        emit Migrated(key, initialSqrtPriceX96);
    }

    /// @notice Creates the plan for the position manager to mint the full range position
    /// @return The plan for the position manager
    function _createPlan() internal view returns (bytes memory, bytes memory) {
        bytes memory actions;
        bytes[] memory params = new bytes[](4);

        actions = abi.encodePacked(
            uint8(Actions.SETTLE),
            uint8(Actions.SETTLE),
            uint8(Actions.MINT_POSITION_FROM_DELTAS),
            uint8(Actions.TAKE_PAIR)
        );

        if (key.currency0 == Currency.wrap(currency)) {
            params[0] = abi.encode(key.currency0, initialCurrencyAmount, false);
            params[1] = abi.encode(key.currency1, initialTokenAmount, false);
        } else {
            params[0] = abi.encode(key.currency0, initialTokenAmount, false);
            params[1] = abi.encode(key.currency1, initialCurrencyAmount, false);
        }

        params[2] = abi.encode(
            key,
            TickMath.MIN_TICK,
            TickMath.MAX_TICK,
            type(uint128).max,
            type(uint128).max,
            positionRecipient,
            Constants.ZERO_BYTES
        );

        params[3] = abi.encode(key.currency0, key.currency1, positionRecipient); // where should dust go? if position recipient is a contract, it may have to be able to accept ETH

        bytes memory newActions;
        bytes[] memory newParams;

        // if reserveSupply - initialTokenAmount != 0, create one sided position
        // if new tick does not go past min or max tick, create a one sided position. else tokens will stay in this contract (extreme case)
        if (reserveSupply - initialTokenAmount != 0) {
            int24 initialTick = TickMath.getTickAtSqrtPrice(initialSqrtPriceX96);

            // if amt of ticks between absolute value of current tick and max tick is less than tick spacing, cannot create
            if (TickMath.MAX_TICK - initialTick > key.tickSpacing && initialTick - TickMath.MIN_TICK >= key.tickSpacing)
            {
                // create new actions and params
                newActions = abi.encodePacked(uint8(Actions.SETTLE), uint8(Actions.MINT_POSITION_FROM_DELTAS));
                newParams = new bytes[](2);
                newParams[0] = abi.encode(Currency.wrap(token), reserveSupply - initialTokenAmount, false);
                if (key.currency0 == Currency.wrap(currency)) {
                    newParams[1] = abi.encode(
                        key,
                        TickMath.MIN_TICK,
                        // could be current tick or lower
                        // what if this is max tick? - full range. okay?
                        // if this is min tick or less, cannot create! (if current tick - min tick < tick spacing, cannot create)
                        (
                            initialTick / key.tickSpacing
                                - (initialTick % key.tickSpacing != 0 && initialTick < 0 ? int24(1) : int24(0))
                        ) * key.tickSpacing, // go to previous tick or self that is a multiple of tick spacing; upper tick is exclusive
                        0, // one sided position - no currency will be sent, only token
                        type(uint128).max,
                        positionRecipient,
                        Constants.ZERO_BYTES
                    );
                } else {
                    newParams[1] = abi.encode(
                        key,
                        // will never be min tick.
                        // current is min, this would be [min+1, MAX)
                        // if this is max tick or greater, cannot create! (if max tick - current tick < tick spacing, cannot create)
                        (initialTick / key.tickSpacing + 1) * key.tickSpacing, // go to next tick that is a multiple of tick spacing; lower tick is inclusive
                        TickMath.MAX_TICK,
                        type(uint128).max,
                        0, // one sided position - no currency will be sent, only token
                        positionRecipient,
                        Constants.ZERO_BYTES
                    );
                }
            }
        }

        return (abi.encode(actions, params), abi.encode(newActions, newParams));
    }
}
