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
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IDistributionStrategy} from "../interfaces/IDistributionStrategy.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookBasic} from "../utils/HookBasic.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";

contract LBPStrategyBasic is ILBPStrategyBasic, HookBasic {
    using CustomRevert for bytes4;

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
    uint256 public tokenAmount;

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

        uint256 auctionSupply = totalSupply * parameters.tokenSplit / 100;

        // require tokenSplit less than or equal to 50?

        auction = address(
            IDistributionStrategy(auctionFactory).initializeDistribution(token, auctionSupply, auctionParamsEncoded)
        );
        IERC20(token).transfer(auction, auctionSupply);
        IDistributionContract(auction).onTokensReceived(token, auctionSupply);
    }

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
            planner.add(Actions.SETTLE, abi.encode(currency1, tokenAmount, true));
        } else {
            planner.add(Actions.SETTLE, abi.encode(currency0, tokenAmount, true));
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

    function onTokensReceived(address _token, uint256 _amount) external view {
        if (_token != address(token)) InvalidToken.selector.revertWith();
        if (_amount != totalSupply) InvalidAmount.selector.revertWith();
        if (IERC20(token).balanceOf(address(this)) != _amount) InvalidAmountReceived.selector.revertWith();
    }

    // on the auction side, the sqrt price will be inverted if the currency address is less than the token address
    function setInitialPrice(uint160 _sqrtPriceX96, uint256 _tokenAmount) public payable {
        // only auction can set initial price
        if (msg.sender != auction) InvalidSender.selector.revertWith();
        sqrtPriceX96 = _sqrtPriceX96;
        tokenAmount = _tokenAmount;
    }
}
