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
import {IBasicMigrator} from "../interfaces/IBasicMigrator.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract BasicMigrator is IBasicMigrator {
    error MigrationNotAllowed();
    error Unauthorized();

    uint24 public immutable fee;
    int24 public immutable tickSpacing;
    IHooks public immutable hooks;
    bytes public hookData;
    address public immutable positionRecipient;
    address public immutable tokensRecipient;
    uint64 public immutable migrationBlock;
    uint256 public immutable totalSupply;
    address public immutable token;
    address public immutable currency;
    uint256 public immutable tokenAmount;

    IPositionManager public immutable positionManager;

    Currency public immutable currency0;
    Currency public immutable currency1;

    constructor(MigratorParameters memory parameters) {
        token = parameters.token;
        currency = parameters.currency;
        totalSupply = parameters.totalSupply;
        positionManager = IPositionManager(parameters.positionManager);
        fee = parameters.fee;
        tickSpacing = parameters.tickSpacing;
        hooks = parameters.hooks;
        hookData = parameters.hookData;
        positionRecipient = parameters.positionRecipient;
        migrationBlock = parameters.migrationBlock;

        (currency0, currency1) = currency < token
            ? (Currency.wrap(currency), Currency.wrap(token))
            : (Currency.wrap(token), Currency.wrap(currency));
    }

    function migrate() public {
        if (block.number < migrationBlock) revert MigrationNotAllowed();

        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: fee, tickSpacing: tickSpacing, hooks: hooks});

        // initialize pool
        // does not revert if pool already exists
        // need to calculate sqrtPriceX96
        // positionManager.initializePool(key, sqrtPriceX96);

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
                hookData
            )
        );

        bytes memory plan = planner.encode();

        positionManager.modifyLiquidities(plan, block.timestamp + 1);
    }

    function onTokensReceived(address _token, uint256 _amount) external view {
        if (_token != address(token)) revert IDistributionContract.InvalidToken();
        if (_amount != totalSupply) revert IDistributionContract.InvalidAmount();
        if (IERC20(token).balanceOf(address(this)) != _amount) revert IDistributionContract.InvalidAmountReceived();
    }

    function setInitialPrice(address _currency, uint256 _amount, uint256 _price) public payable {
        // can only be called once by auction contract - how to enforce this?
        // if currency == address(0), require msg.value == amount
        if (_currency != address(currency)) revert IDistributionContract.InvalidCurrency();
        // price is currency / token
        // to find token amount to add liquidity:
        //   amt token = amt currency / price
        // total supply - amt token = leftover tokens
    }
}
