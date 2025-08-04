// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IDistributionContract} from "../interfaces/IDistributionContract.sol";
import {MigratorParameters} from "../types/MigratorParams.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Plan, Planner} from "../libraries/Planner.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {ILBPStrategyBasic} from "../interfaces/ILBPStrategyBasic.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IDistributionStrategy} from "../interfaces/IDistributionStrategy.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookBasic} from "../utils/HookBasic.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title LBPStrategyBasic
/// @notice Basic Strategy to distribute tokens and raise funds from an auction to a v4 pool
contract LBPStrategyBasic is ILBPStrategyBasic, HookBasic {
    using CustomRevert for bytes4;
    using SafeERC20 for IERC20;

    /// @notice The token split is measured in bips (10000 = 100%)
    uint24 public constant MAX_TOKEN_SPLIT = 10000;

    address public immutable token;
    address public immutable currency;

    uint24 public immutable fee;
    uint256 public immutable totalSupply;
    int24 public immutable tickSpacing;
    address public immutable positionRecipient;
    uint64 public immutable migrationBlock;
    address public immutable auctionFactory;
    address public immutable auction;

    IPositionManager public immutable positionManager;

    uint160 public sqrtPriceX96;
    uint256 public tokensForInitialPosition;

    constructor(address _token, uint256 _totalSupply, bytes memory configData) HookBasic(configData) {
        (MigratorParameters memory parameters, bytes memory auctionParamsEncoded) =
            abi.decode(configData, (MigratorParameters, bytes));

        token = _token;
        currency = parameters.currency;
        totalSupply = _totalSupply;
        positionManager = IPositionManager(parameters.positionManager);
        fee = parameters.fee;
        tickSpacing = parameters.tickSpacing;
        positionRecipient = parameters.positionRecipient;
        migrationBlock = parameters.migrationBlock;
        auctionFactory = parameters.auctionFactory;

        uint256 auctionSupply = totalSupply * parameters.tokenSplit / MAX_TOKEN_SPLIT;

        auction = address(
            IDistributionStrategy(auctionFactory).initializeDistribution(token, auctionSupply, auctionParamsEncoded)
        );
        IERC20(token).safeTransfer(auction, auctionSupply);
        IDistributionContract(auction).onTokensReceived(token, auctionSupply);
    }

    /// @inheritdoc ILBPStrategyBasic
    function migrate() public {
        if (block.number < migrationBlock) MigrationNotAllowed.selector.revertWith();

        (Currency currency0, Currency currency1) = currency < token
            ? (Currency.wrap(currency), Currency.wrap(token))
            : (Currency.wrap(token), Currency.wrap(currency));

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(this))
        });

        // initialize pool with starting price
        positionManager.initializePool(key, sqrtPriceX96);

        Plan memory planner = Planner.init();

        if (currency0 == Currency.wrap(currency)) {
            planner.add(Actions.SETTLE, abi.encode(currency0, currency0.balanceOf(address(this)), true));
            planner.add(Actions.SETTLE, abi.encode(currency1, tokensForInitialPosition, true));
        } else {
            planner.add(Actions.SETTLE, abi.encode(currency0, tokensForInitialPosition, true));
            planner.add(Actions.SETTLE, abi.encode(currency1, currency1.balanceOf(address(this)), true));
        }
        planner.add(
            Actions.MINT_POSITION_FROM_DELTAS,
            abi.encode(
                key,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                type(uint128).max,
                type(uint128).max,
                positionRecipient,
                Constants.ZERO_BYTES
            )
        );

        bytes memory plan = planner.encode();

        positionManager.modifyLiquidities(plan, block.timestamp + 1);
    }

    /// @inheritdoc IDistributionContract
    function onTokensReceived(address _token, uint256 _amount) external view {
        if (_token != address(token)) InvalidToken.selector.revertWith();
        if (_amount != totalSupply) IncorrectTokenSupply.selector.revertWith();
        if (IERC20(token).balanceOf(address(this)) != _amount) InvalidAmountReceived.selector.revertWith();
    }

    /// @inheritdoc ILBPStrategyBasic
    /// @dev The sqrt price will be opposite the auction price if the currency address is less than the token address
    function setInitialPrice(uint160 _sqrtPriceX96, uint256 _tokensForInitialPosition) public payable {
        if (msg.sender != auction) OnlyAuctionCanSetPrice.selector.revertWith();
        sqrtPriceX96 = _sqrtPriceX96;
        tokensForInitialPosition = _tokensForInitialPosition;
    }
}
