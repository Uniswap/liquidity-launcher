// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StrategyPlanner} from "../../src/libraries/StrategyPlanner.sol";
import {BasePositionParams, FullRangeParams, OneSidedParams} from "../../src/types/PositionTypes.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {ActionsBuilder} from "../../src/libraries/ActionsBuilder.sol";
import {ParamsBuilder} from "../../src/libraries/ParamsBuilder.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TickBounds} from "../../src/types/PositionTypes.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickCalculations} from "../../src/libraries/TickCalculations.sol";

contract StrategyPlannerHelper is Test {
    function planFullRangePosition(
        BasePositionParams memory baseParams,
        FullRangeParams memory fullRangeParams,
        uint256 paramsArraySize
    ) public pure returns (bytes memory actions, bytes[] memory params) {
        return StrategyPlanner.planFullRangePosition(baseParams, fullRangeParams, paramsArraySize);
    }

    function planOneSidedPosition(
        BasePositionParams memory baseParams,
        OneSidedParams memory oneSidedParams,
        bytes memory existingActions,
        bytes[] memory existingParams
    ) public pure returns (bytes memory actions, bytes[] memory params) {
        return StrategyPlanner.planOneSidedPosition(baseParams, oneSidedParams, existingActions, existingParams);
    }
}

contract StrategyPlannerTest is Test {
    using TickCalculations for int24;

    StrategyPlannerHelper testHelper;

    function setUp() public {
        testHelper = new StrategyPlannerHelper();
    }

    function test_planFullRangePosition_succeeds() public view {
        (bytes memory actions, bytes[] memory params) = testHelper.planFullRangePosition(
            BasePositionParams({
                currency: address(0),
                token: address(1),
                poolLPFee: 10000,
                poolTickSpacing: 1,
                initialSqrtPriceX96: TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK),
                liquidity: 1000000000000000000,
                positionRecipient: address(0),
                hooks: IHooks(address(0))
            }),
            FullRangeParams({tokenAmount: 1000000000000000000, currencyAmount: 1000000000000000000}),
            5
        );
        assertEq(actions.length, 5);
        assertEq(params.length, 5);
        assertEq(actions, ActionsBuilder.buildFullRangeActions());
        assertEq(params[0], abi.encode(Currency.wrap(address(0)), 1000000000000000000, false));
        assertEq(params[1], abi.encode(Currency.wrap(address(1)), 1000000000000000000, false));
        assertEq(
            params[2],
            abi.encode(
                PoolKey({
                    currency0: Currency.wrap(address(0)),
                    currency1: Currency.wrap(address(1)),
                    fee: 10000,
                    tickSpacing: 1,
                    hooks: IHooks(address(0))
                }),
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                1000000000000000000,
                1000000000000000000,
                address(0),
                ParamsBuilder.ZERO_BYTES
            )
        );
        assertEq(params[3], abi.encode(Currency.wrap(address(0)), type(uint256).max));
        assertEq(params[4], abi.encode(Currency.wrap(address(1)), type(uint256).max));
    }

    function test_fuzz_planFullRangePosition_succeeds(
        BasePositionParams memory baseParams,
        FullRangeParams memory fullRangeParams
    ) public view {
        baseParams.poolTickSpacing =
            int24(bound(baseParams.poolTickSpacing, TickMath.MIN_TICK_SPACING, TickMath.MAX_TICK_SPACING));
        baseParams.poolLPFee = uint24(bound(baseParams.poolLPFee, 0, LPFeeLibrary.MAX_LP_FEE));
        baseParams.liquidity = uint128(bound(baseParams.liquidity, 0, type(uint128).max));
        baseParams.initialSqrtPriceX96 =
            uint160(bound(baseParams.initialSqrtPriceX96, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE));
        fullRangeParams.tokenAmount = uint128(bound(fullRangeParams.tokenAmount, 0, type(uint128).max));
        fullRangeParams.currencyAmount = uint128(bound(fullRangeParams.currencyAmount, 0, type(uint128).max));

        uint256 arraySize = 5;
        (bytes memory actions, bytes[] memory params) =
            testHelper.planFullRangePosition(baseParams, fullRangeParams, arraySize);
        assertEq(actions.length, arraySize);
        assertEq(params.length, arraySize);
        assertEq(actions, ActionsBuilder.buildFullRangeActions());
        assertEq(
            params[0],
            abi.encode(
                Currency.wrap(baseParams.currency < baseParams.token ? baseParams.currency : baseParams.token),
                baseParams.currency < baseParams.token ? fullRangeParams.currencyAmount : fullRangeParams.tokenAmount,
                false
            )
        );
        assertEq(
            params[1],
            abi.encode(
                Currency.wrap(baseParams.currency < baseParams.token ? baseParams.token : baseParams.currency),
                baseParams.currency < baseParams.token ? fullRangeParams.tokenAmount : fullRangeParams.currencyAmount,
                false
            )
        );
        assertEq(
            params[2],
            abi.encode(
                PoolKey({
                    currency0: Currency.wrap(
                        baseParams.currency < baseParams.token ? baseParams.currency : baseParams.token
                    ),
                    currency1: Currency.wrap(
                        baseParams.currency < baseParams.token ? baseParams.token : baseParams.currency
                    ),
                    fee: baseParams.poolLPFee,
                    tickSpacing: baseParams.poolTickSpacing,
                    hooks: baseParams.hooks
                }),
                TickMath.MIN_TICK / baseParams.poolTickSpacing * baseParams.poolTickSpacing,
                TickMath.MAX_TICK / baseParams.poolTickSpacing * baseParams.poolTickSpacing,
                baseParams.currency < baseParams.token ? fullRangeParams.currencyAmount : fullRangeParams.tokenAmount,
                baseParams.currency < baseParams.token ? fullRangeParams.tokenAmount : fullRangeParams.currencyAmount,
                baseParams.positionRecipient,
                ParamsBuilder.ZERO_BYTES
            )
        );
        assertEq(
            params[3],
            abi.encode(
                Currency.wrap(baseParams.currency < baseParams.token ? baseParams.currency : baseParams.token),
                type(uint256).max
            )
        );
        assertEq(
            params[4],
            abi.encode(
                Currency.wrap(baseParams.currency < baseParams.token ? baseParams.token : baseParams.currency),
                type(uint256).max
            )
        );
    }

    function test_planOneSidedPosition_inToken_succeeds() public view {
        bytes memory existingActions = ActionsBuilder.buildFullRangeActions();
        bytes[] memory existingParams = ParamsBuilder.buildFullRangeParams(
            FullRangeParams({tokenAmount: 1000000000000000000, currencyAmount: 1000000000000000000}),
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(address(1)),
                fee: 10000,
                tickSpacing: 1,
                hooks: IHooks(address(0))
            }),
            TickBounds({lowerTick: TickMath.MIN_TICK, upperTick: TickMath.MAX_TICK}),
            true,
            8,
            address(0)
        );
        (bytes memory actions, bytes[] memory params) = testHelper.planOneSidedPosition(
            BasePositionParams({
                currency: address(0),
                token: address(1),
                poolLPFee: 10000,
                poolTickSpacing: 1,
                initialSqrtPriceX96: TickMath.getSqrtPriceAtTick(0),
                liquidity: 1000000000000000000,
                positionRecipient: address(0),
                hooks: IHooks(address(0))
            }),
            OneSidedParams({amount: 1000000000000000000, inToken: true}),
            existingActions,
            existingParams
        );
        assertEq(actions.length, 8);
        assertEq(params.length, 8);
        assertEq(actions, ActionsBuilder.buildOneSidedActions(existingActions));
        assertEq(params[0], abi.encode(Currency.wrap(address(0)), 1000000000000000000, false));
        assertEq(params[1], abi.encode(Currency.wrap(address(1)), 1000000000000000000, false));
        assertEq(
            params[2],
            abi.encode(
                PoolKey({
                    currency0: Currency.wrap(address(0)),
                    currency1: Currency.wrap(address(1)),
                    fee: 10000,
                    tickSpacing: 1,
                    hooks: IHooks(address(0))
                }),
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                1000000000000000000,
                1000000000000000000,
                address(0),
                ParamsBuilder.ZERO_BYTES
            )
        );
        assertEq(params[3], abi.encode(Currency.wrap(address(0)), type(uint256).max));
        assertEq(params[4], abi.encode(Currency.wrap(address(1)), type(uint256).max));
        assertEq(params[5], abi.encode(Currency.wrap(address(1)), 1000000000000000000, false));
        assertEq(
            params[6],
            abi.encode(
                PoolKey({
                    currency0: Currency.wrap(address(0)),
                    currency1: Currency.wrap(address(1)),
                    fee: 10000,
                    tickSpacing: 1,
                    hooks: IHooks(address(0))
                }),
                TickMath.MIN_TICK,
                0,
                0,
                1000000000000000000,
                address(0),
                ParamsBuilder.ZERO_BYTES
            )
        );
        assertEq(params[7], abi.encode(Currency.wrap(address(1)), type(uint256).max));
    }

    function test_planOneSidedPosition_inCurrency_succeeds() public view {
        bytes memory existingActions = ActionsBuilder.buildFullRangeActions();
        bytes[] memory existingParams = ParamsBuilder.buildFullRangeParams(
            FullRangeParams({tokenAmount: 1000000000000000000, currencyAmount: 1000000000000000000}),
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(address(1)),
                fee: 10000,
                tickSpacing: 1,
                hooks: IHooks(address(0))
            }),
            TickBounds({lowerTick: TickMath.MIN_TICK, upperTick: TickMath.MAX_TICK}),
            true,
            8,
            address(0)
        );
        (bytes memory actions, bytes[] memory params) = testHelper.planOneSidedPosition(
            BasePositionParams({
                currency: address(0),
                token: address(1),
                poolLPFee: 10000,
                poolTickSpacing: 1,
                initialSqrtPriceX96: TickMath.getSqrtPriceAtTick(0),
                liquidity: 1000000000000000000,
                positionRecipient: address(0),
                hooks: IHooks(address(0))
            }),
            OneSidedParams({amount: 1000000000000000000, inToken: false}),
            existingActions,
            existingParams
        );
        assertEq(actions.length, 8);
        assertEq(params.length, 8);
        assertEq(actions, ActionsBuilder.buildOneSidedActions(existingActions));
        assertEq(params[0], abi.encode(Currency.wrap(address(0)), 1000000000000000000, false));
        assertEq(params[1], abi.encode(Currency.wrap(address(1)), 1000000000000000000, false));
        assertEq(
            params[2],
            abi.encode(
                PoolKey({
                    currency0: Currency.wrap(address(0)),
                    currency1: Currency.wrap(address(1)),
                    fee: 10000,
                    tickSpacing: 1,
                    hooks: IHooks(address(0))
                }),
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                1000000000000000000,
                1000000000000000000,
                address(0),
                ParamsBuilder.ZERO_BYTES
            )
        );
        assertEq(params[3], abi.encode(Currency.wrap(address(0)), type(uint256).max));
        assertEq(params[4], abi.encode(Currency.wrap(address(1)), type(uint256).max));
        assertEq(params[5], abi.encode(Currency.wrap(address(0)), 1000000000000000000, false));
        assertEq(
            params[6],
            abi.encode(
                PoolKey({
                    currency0: Currency.wrap(address(0)),
                    currency1: Currency.wrap(address(1)),
                    fee: 10000,
                    tickSpacing: 1,
                    hooks: IHooks(address(0))
                }),
                1,
                TickMath.MAX_TICK,
                1000000000000000000,
                0,
                address(0),
                ParamsBuilder.ZERO_BYTES
            )
        );
        assertEq(params[7], abi.encode(Currency.wrap(address(0)), type(uint256).max));
    }

    // function test_fuzz_planOneSidedPosition_succeeds(
    //     BasePositionParams memory baseParams,
    //     OneSidedParams memory oneSidedParams,
    //     FullRangeParams memory fullRangeParams
    // ) public view {
    //     baseParams.poolTickSpacing =
    //         int24(bound(baseParams.poolTickSpacing, TickMath.MIN_TICK_SPACING, TickMath.MAX_TICK_SPACING));
    //     baseParams.poolLPFee = uint24(bound(baseParams.poolLPFee, 0, LPFeeLibrary.MAX_LP_FEE));
    //     baseParams.liquidity = uint128(bound(baseParams.liquidity, 0, type(uint128).max));
    //     baseParams.initialSqrtPriceX96 =
    //         uint160(bound(baseParams.initialSqrtPriceX96, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE));
    //     fullRangeParams.tokenAmount = uint128(bound(fullRangeParams.tokenAmount, 0, type(uint128).max));
    //     fullRangeParams.currencyAmount = uint128(bound(fullRangeParams.currencyAmount, 0, type(uint128).max));

    //     oneSidedParams.amount = oneSidedParams.inToken ? uint128(bound(oneSidedParams.amount, 1, type(uint128).max - fullRangeParams.tokenAmount)) : uint128(bound(oneSidedParams.amount, 1, type(uint128).max - fullRangeParams.currencyAmount));

    //     uint256 arraySize = 8;
    //     (bytes memory fullActions, bytes[] memory fullParams) =
    //         testHelper.planFullRangePosition(baseParams, fullRangeParams, arraySize);

    //     (bytes memory actions, bytes[] memory params) =
    //         testHelper.planOneSidedPosition(baseParams, oneSidedParams, fullActions, fullParams);
    //     if (actions.length == 5) {
    //         assertEq(actions, fullActions);
    //         assertEq(params, ParamsBuilder.truncateParams(fullParams));
    //     } else {
    //         assertEq(actions.length, arraySize);
    //         assertEq(params.length, arraySize);
    //         assertEq(actions, ActionsBuilder.buildOneSidedActions(fullActions));
    //         assertEq(
    //             params[5],
    //             abi.encode(
    //                 Currency.wrap(oneSidedParams.inToken ? baseParams.token : baseParams.currency),
    //                 oneSidedParams.amount,
    //                 false
    //             )
    //         );
    //         assertEq(
    //             params[6],
    //             abi.encode(
    //                 PoolKey({
    //                     currency0: Currency.wrap(
    //                         baseParams.currency < baseParams.token ? baseParams.currency : baseParams.token
    //                     ),
    //                     currency1: Currency.wrap(
    //                         baseParams.currency < baseParams.token ? baseParams.token : baseParams.currency
    //                     ),
    //                     fee: baseParams.poolLPFee,
    //                     tickSpacing: baseParams.poolTickSpacing,
    //                     hooks: baseParams.hooks
    //                 }),
    //                 baseParams.currency < baseParams.token == oneSidedParams.inToken
    //                     ? TickMath.MIN_TICK / baseParams.poolTickSpacing * baseParams.poolTickSpacing
    //                     : TickMath.getTickAtSqrtPrice(baseParams.initialSqrtPriceX96).tickStrictCeil(
    //                         baseParams.poolTickSpacing
    //                     ),
    //                 baseParams.currency < baseParams.token == oneSidedParams.inToken
    //                     ? TickMath.getTickAtSqrtPrice(baseParams.initialSqrtPriceX96).tickFloor(baseParams.poolTickSpacing)
    //                     : TickMath.MAX_TICK / baseParams.poolTickSpacing * baseParams.poolTickSpacing,
    //                 baseParams.currency < baseParams.token == oneSidedParams.inToken ? 0 : oneSidedParams.amount,
    //                 baseParams.currency < baseParams.token == oneSidedParams.inToken ? oneSidedParams.amount : 0,
    //                 baseParams.positionRecipient,
    //                 ParamsBuilder.ZERO_BYTES
    //             )
    //         );
    //         assertEq(
    //             params[7],
    //             abi.encode(
    //                 Currency.wrap(oneSidedParams.inToken ? baseParams.token : baseParams.currency), type(uint256).max
    //             )
    //         );
    //     }

    //     assertEq(
    //         params[0],
    //         abi.encode(
    //             Currency.wrap(baseParams.currency < baseParams.token ? baseParams.currency : baseParams.token),
    //             baseParams.currency < baseParams.token ? fullRangeParams.currencyAmount : fullRangeParams.tokenAmount,
    //             false
    //         )
    //     );
    //     assertEq(
    //         params[1],
    //         abi.encode(
    //             Currency.wrap(baseParams.currency < baseParams.token ? baseParams.token : baseParams.currency),
    //             baseParams.currency < baseParams.token ? fullRangeParams.tokenAmount : fullRangeParams.currencyAmount,
    //             false
    //         )
    //     );
    //     assertEq(
    //         params[2],
    //         abi.encode(
    //             PoolKey({
    //                 currency0: Currency.wrap(
    //                     baseParams.currency < baseParams.token ? baseParams.currency : baseParams.token
    //                 ),
    //                 currency1: Currency.wrap(
    //                     baseParams.currency < baseParams.token ? baseParams.token : baseParams.currency
    //                 ),
    //                 fee: baseParams.poolLPFee,
    //                 tickSpacing: baseParams.poolTickSpacing,
    //                 hooks: baseParams.hooks
    //             }),
    //             TickMath.MIN_TICK / baseParams.poolTickSpacing * baseParams.poolTickSpacing,
    //             TickMath.MAX_TICK / baseParams.poolTickSpacing * baseParams.poolTickSpacing,
    //             baseParams.currency < baseParams.token ? fullRangeParams.currencyAmount : fullRangeParams.tokenAmount,
    //             baseParams.currency < baseParams.token ? fullRangeParams.tokenAmount : fullRangeParams.currencyAmount,
    //             baseParams.positionRecipient,
    //             ParamsBuilder.ZERO_BYTES
    //         )
    //     );
    //     assertEq(
    //         params[3],
    //         abi.encode(
    //             Currency.wrap(baseParams.currency < baseParams.token ? baseParams.currency : baseParams.token),
    //             type(uint256).max
    //         )
    //     );
    //     assertEq(
    //         params[4],
    //         abi.encode(
    //             Currency.wrap(baseParams.currency < baseParams.token ? baseParams.token : baseParams.currency),
    //             type(uint256).max
    //         )
    //     );
    // }
}
