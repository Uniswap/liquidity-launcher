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
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";

contract BasicMigrator is IDistributionContract {
    error MigrationNotAllowed();
    error Unauthorized();

    uint24 public immutable fee;
    int24 public immutable tickSpacing;
    IHooks public immutable hooks;
    bytes public hookData;
    address public immutable positionRecipient;
    address public immutable tokensRecipient;
    uint64 public immutable migrationBlock;

    Currency public token;
    Currency public currency0;
    Currency public currency1;

    /// @notice Address of the Uniswap V4 Position Manager contract
    PositionManager public immutable positionManager;

    constructor(MigratorParameters memory parameters, PositionManager posm) {
        fee = parameters.fee;
        tickSpacing = parameters.tickSpacing;
        hooks = parameters.hooks;
        hookData = parameters.hookData;
        positionRecipient = parameters.positionRecipient;
        tokensRecipient = parameters.tokensRecipient;
        migrationBlock = parameters.migrationBlock;
        positionManager = posm;
    }

    function migrate() public {
        if (block.number < migrationBlock) revert MigrationNotAllowed();
        // if sqrtPrice == 0, revert

        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: fee, tickSpacing: tickSpacing, hooks: hooks});

        Plan memory planner = Planner.init();
        planner.add(Actions.SETTLE, abi.encode(currency0, currency0.balanceOf(address(this)), true));
        planner.add(Actions.SETTLE, abi.encode(currency1, currency1.balanceOf(address(this)), true));
        planner.add(
            Actions.MINT_POSITION_FROM_DELTAS,
            abi.encode(key, TickMath.MIN_TICK, TickMath.MAX_TICK, 0, 0, positionRecipient, hookData)
        );

        bytes memory plan = planner.encode();

        positionManager.modifyLiquidities(plan, block.timestamp + 1);
    }

    function onTokensReceived(address tokeAddress, uint256 amount) public {
        // can only be called once
        // token = token;
        // initialAmount = amount;
        // tokendecimals = x;
    }

    function setInitialPrice(Currency currency, uint256 amount) public payable {
        // can only be called once
        (currency0, currency1) = currency < token ? (currency, token) : (token, currency);
        // if currency == address(0), require msg.value == amount
        // gives sqrt price
        // sqrtPrice = x;
        // currencyDecimals = x;
    }

    function withdrawLeftoverTokens() public {
        // if token == currency1, need to calculate token1 amount
        // else token == currency0, need to calculate token0 amount
        // if withdrawn == true, revert
        if (msg.sender != tokensRecipient) revert Unauthorized();
        // withdrawn = true;
        // TODO: Implement withdrawal logic
        // based on initial price and eth in contract, calculate amount of tokens that need to be withdrawn
        // calculate leftover tokens
        // leftoverTokens = x;
        // transfer leftoverTokens to tokensRecipient
    }
}
