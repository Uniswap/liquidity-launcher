// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ParamsBuilder} from "../../src/libraries/ParamsBuilder.sol";
import {FullRangeParams, OneSidedParams} from "../../src/types/PositionTypes.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickBounds} from "../../src/types/PositionTypes.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";

// Test helper contract to expose internal library functions for testing
contract ParamsBuilderTestHelper {
    using ParamsBuilder for *;

    function buildFullRangeParams(
        FullRangeParams memory fullRangeParams,
        PoolKey memory poolKey,
        TickBounds memory bounds,
        bool currencyIsCurrency0,
        uint256 paramsArraySize,
        address positionRecipient,
        uint128 liquidity
    ) external pure returns (bytes[] memory) {
        return ParamsBuilder.buildFullRangeParams(
            fullRangeParams, poolKey, bounds, currencyIsCurrency0, paramsArraySize, positionRecipient, liquidity
        );
    }

    function buildOneSidedParams(
        OneSidedParams memory oneSidedParams,
        PoolKey memory poolKey,
        TickBounds memory bounds,
        bool currencyIsCurrency0,
        bytes[] memory existingParams,
        address positionRecipient,
        uint128 liquidity
    ) external pure returns (bytes[] memory) {
        return ParamsBuilder.buildOneSidedParams(
            oneSidedParams, poolKey, bounds, currencyIsCurrency0, existingParams, positionRecipient, liquidity
        );
    }

    function truncateParams(bytes[] memory params) external pure returns (bytes[] memory) {
        return ParamsBuilder.truncateParams(params);
    }
}

contract ParamsBuilderTest is Test {
    ParamsBuilderTestHelper testHelper;

    function setUp() public {
        testHelper = new ParamsBuilderTestHelper();
    }

    function test_buildFullRangeParams_revertsWithInvalidParamsLength() public {
        vm.expectRevert(abi.encodeWithSelector(ParamsBuilder.InvalidParamsLength.selector, 1));
        testHelper.buildFullRangeParams(
            FullRangeParams({tokenAmount: 100e18, currencyAmount: 100e18}),
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(address(1)),
                fee: 10000,
                tickSpacing: 1,
                hooks: IHooks(address(0))
            }),
            TickBounds({lowerTick: TickMath.MIN_TICK, upperTick: TickMath.MAX_TICK}),
            true,
            1,
            address(3),
            100e18
        );
    }

    function test_buildFullRangeParams_succeeds() public view {
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            TickMath.getSqrtPriceAtTick(0),
            TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK),
            TickMath.getSqrtPriceAtTick(TickMath.MAX_TICK),
            100e18,
            10e18
        );
        bytes[] memory params = testHelper.buildFullRangeParams(
            FullRangeParams({tokenAmount: 10e18, currencyAmount: 100e18}),
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(address(1)),
                fee: 10000,
                tickSpacing: 1,
                hooks: IHooks(address(0))
            }),
            TickBounds({lowerTick: TickMath.MIN_TICK, upperTick: TickMath.MAX_TICK}),
            true,
            ParamsBuilder.FULL_RANGE_SIZE + ParamsBuilder.FINAL_TAKE_PAIR_SIZE,
            address(3),
            liquidity
        );
        assertEq(params.length, ParamsBuilder.FULL_RANGE_SIZE + ParamsBuilder.FINAL_TAKE_PAIR_SIZE);
        assertEq(
            params[0],
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
                liquidity,
                100e18,
                10e18,
                address(3),
                ParamsBuilder.ZERO_BYTES
            )
        );
        assertEq(params[1], abi.encode(Currency.wrap(address(0)), ActionConstants.CONTRACT_BALANCE, false));
        assertEq(params[2], abi.encode(Currency.wrap(address(1)), ActionConstants.CONTRACT_BALANCE, false));
    }

    // function test_fuzz_buildFullRangeParams_succeeds(
    //     PoolKey memory poolKey,
    //     TickBounds memory bounds,
    //     bool currencyIsCurrency0,
    //     uint128 tokenAmount,
    //     uint128 currencyAmount
    // ) public view {
    // uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
    //     TickMath.getSqrtPriceAtTick(0),
    //     TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK),
    //     TickMath.getSqrtPriceAtTick(TickMath.MAX_TICK),
    //     currencyIsCurrency0 ? currencyAmount : tokenAmount,
    //     currencyIsCurrency0 ? tokenAmount : currencyAmount
    // );
    // bytes[] memory params = testHelper.buildFullRangeParams(
    //     FullRangeParams({tokenAmount: tokenAmount, currencyAmount: currencyAmount}),
    //     poolKey,
    //     bounds,
    //     currencyIsCurrency0,
    //     ParamsBuilder.FULL_RANGE_SIZE,
    //     address(3),
    //     liquidity
    // );

    // assertEq(params.length, ParamsBuilder.FULL_RANGE_SIZE);

    // assertEq(
    //     params[0],
    //     abi.encode(
    //         poolKey,
    //         bounds.lowerTick,
    //         bounds.upperTick,
    //         liquidity,
    //         currencyIsCurrency0 ? currencyAmount : tokenAmount,
    //         currencyIsCurrency0 ? tokenAmount : currencyAmount,
    //         address(3),
    //         ParamsBuilder.ZERO_BYTES
    //     )
    // );

    // assertEq(params[1], abi.encode(poolKey.currency0, ActionConstants.OPEN_DELTA, false));
    // assertEq(params[2], abi.encode(poolKey.currency1, ActionConstants.OPEN_DELTA, false));

    // assertEq(params[3], abi.encode(poolKey.currency0, address(this)));
    // assertEq(params[4], abi.encode(poolKey.currency1, address(this)));
    //}

    function test_buildOneSidedParams_revertsWithInvalidParamsLength() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ParamsBuilder.InvalidParamsLength.selector, ParamsBuilder.FULL_RANGE_WITH_ONE_SIDED_SIZE - 1
            )
        );
        testHelper.buildOneSidedParams(
            OneSidedParams({amount: 10e18, inToken: true}),
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(address(1)),
                fee: 10000,
                tickSpacing: 1,
                hooks: IHooks(address(0))
            }),
            TickBounds({lowerTick: TickMath.MIN_TICK, upperTick: TickMath.MAX_TICK}),
            true,
            new bytes[](ParamsBuilder.FULL_RANGE_WITH_ONE_SIDED_SIZE - 1),
            address(3),
            LiquidityAmounts.getLiquidityForAmounts(
                TickMath.getSqrtPriceAtTick(0),
                TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK),
                TickMath.getSqrtPriceAtTick(-1),
                0,
                10e18
            )
        );
    }

    function test_buildOneSidedParams_inToken_succeeds() public view {
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            TickMath.getSqrtPriceAtTick(0),
            TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK),
            TickMath.getSqrtPriceAtTick(TickMath.MAX_TICK),
            100e18,
            10e18
        );
        bytes[] memory fullRangeParams = testHelper.buildFullRangeParams(
            FullRangeParams({tokenAmount: 10e18, currencyAmount: 100e18}),
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(address(1)),
                fee: 10000,
                tickSpacing: 1,
                hooks: IHooks(address(0))
            }),
            TickBounds({lowerTick: TickMath.MIN_TICK, upperTick: TickMath.MAX_TICK}),
            true,
            ParamsBuilder.FULL_RANGE_WITH_ONE_SIDED_SIZE + ParamsBuilder.FINAL_TAKE_PAIR_SIZE,
            address(3),
            liquidity
        );

        uint128 oneSidedLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            TickMath.getSqrtPriceAtTick(0),
            TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK),
            TickMath.getSqrtPriceAtTick(0),
            0,
            10e18
        );

        bytes[] memory params = testHelper.buildOneSidedParams(
            OneSidedParams({amount: 10e18, inToken: true}),
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(address(1)),
                fee: 10000,
                tickSpacing: 1,
                hooks: IHooks(address(0))
            }),
            TickBounds({lowerTick: TickMath.MIN_TICK, upperTick: TickMath.MAX_TICK}),
            true,
            fullRangeParams,
            address(3),
            oneSidedLiquidity
        );
        assertEq(params.length, ParamsBuilder.FULL_RANGE_WITH_ONE_SIDED_SIZE + ParamsBuilder.FINAL_TAKE_PAIR_SIZE);

        assertEq(
            params[0],
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
                liquidity,
                100e18,
                10e18,
                address(3),
                ParamsBuilder.ZERO_BYTES
            )
        );

        assertEq(params[1], abi.encode(Currency.wrap(address(0)), ActionConstants.CONTRACT_BALANCE, false));
        assertEq(params[2], abi.encode(Currency.wrap(address(1)), ActionConstants.CONTRACT_BALANCE, false));

        assertEq(
            params[3],
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
                oneSidedLiquidity,
                0,
                10e18,
                address(3),
                ParamsBuilder.ZERO_BYTES
            )
        );
    }

    function test_buildOneSidedParams_inCurrency_succeeds() public view {
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            TickMath.getSqrtPriceAtTick(0),
            TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK),
            TickMath.getSqrtPriceAtTick(TickMath.MAX_TICK),
            100e18,
            10e18
        );
        bytes[] memory fullRangeParams = testHelper.buildFullRangeParams(
            FullRangeParams({tokenAmount: 10e18, currencyAmount: 100e18}),
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(address(1)),
                fee: 10000,
                tickSpacing: 1,
                hooks: IHooks(address(0))
            }),
            TickBounds({lowerTick: TickMath.MIN_TICK, upperTick: TickMath.MAX_TICK}),
            true,
            ParamsBuilder.FULL_RANGE_WITH_ONE_SIDED_SIZE + ParamsBuilder.FINAL_TAKE_PAIR_SIZE,
            address(3),
            liquidity
        );

        uint128 oneSidedLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            TickMath.getSqrtPriceAtTick(0),
            TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK),
            TickMath.getSqrtPriceAtTick(0),
            0,
            10e18
        );
        bytes[] memory params = testHelper.buildOneSidedParams(
            OneSidedParams({amount: 10e18, inToken: false}),
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(address(1)),
                fee: 10000,
                tickSpacing: 1,
                hooks: IHooks(address(0))
            }),
            TickBounds({lowerTick: TickMath.MIN_TICK, upperTick: TickMath.MAX_TICK}),
            true,
            fullRangeParams,
            address(3),
            oneSidedLiquidity
        );
        assertEq(params.length, ParamsBuilder.FULL_RANGE_WITH_ONE_SIDED_SIZE + ParamsBuilder.FINAL_TAKE_PAIR_SIZE);

        assertEq(
            params[0],
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
                liquidity,
                100e18,
                10e18,
                address(3),
                ParamsBuilder.ZERO_BYTES
            )
        );

        assertEq(params[1], abi.encode(Currency.wrap(address(0)), ActionConstants.CONTRACT_BALANCE, false));
        assertEq(params[2], abi.encode(Currency.wrap(address(1)), ActionConstants.CONTRACT_BALANCE, false));

        assertEq(
            params[3],
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
                oneSidedLiquidity,
                10e18,
                0,
                address(3),
                ParamsBuilder.ZERO_BYTES
            )
        );
    }

    // function test_fuzz_buildOneSidedParams_succeeds(
    //     PoolKey memory poolKey,
    //     TickBounds memory bounds,
    //     uint128 tokenAmount,
    //     uint128 currencyAmount
    // ) public view {
    //     bool currencyIsCurrency0 = poolKey.currency0 < poolKey.currency1;
    //     bool inToken = tokenAmount > currencyAmount;
    //     bool useAmountInCurrency1 = currencyIsCurrency0 == inToken;
    //     uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
    //         TickMath.getSqrtPriceAtTick(0),
    //         TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK),
    //         TickMath.getSqrtPriceAtTick(TickMath.MAX_TICK),
    //         currencyIsCurrency0 ? currencyAmount : tokenAmount,
    //         currencyIsCurrency0 ? tokenAmount : currencyAmount
    //     );
    //     bytes[] memory fullRangeParams = testHelper.buildFullRangeParams(
    //         FullRangeParams({tokenAmount: tokenAmount, currencyAmount: currencyAmount}),
    //         poolKey,
    //         bounds,
    //         currencyIsCurrency0,
    //         ParamsBuilder.FULL_RANGE_WITH_ONE_SIDED_SIZE,
    //         address(3),
    //         liquidity
    //     );
    //     uint128 oneSidedLiquidity = LiquidityAmounts.getLiquidityForAmounts(
    //         TickMath.getSqrtPriceAtTick(0),
    //         TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK),
    //         TickMath.getSqrtPriceAtTick(0),
    //         0,
    //         amount
    //     );
    //     bytes[] memory params = testHelper.buildOneSidedParams(
    //         OneSidedParams({amount: amount, inToken: inToken}),
    //         poolKey,
    //         bounds,
    //         currencyIsCurrency0,
    //         fullRangeParams,
    //         address(3),
    //         oneSidedLiquidity
    //     );

    //     assertEq(params.length, ParamsBuilder.FULL_RANGE_WITH_ONE_SIDED_SIZE);

    //     assertEq(
    //         params[0],
    //         abi.encode(
    //             poolKey,
    //             bounds.lowerTick,
    //             bounds.upperTick,
    //             liquidity,
    //             currencyIsCurrency0 ? currencyAmount : tokenAmount,
    //             currencyIsCurrency0 ? tokenAmount : currencyAmount,
    //             address(3),
    //             ParamsBuilder.ZERO_BYTES
    //         )
    //     );

    //     assertEq(params[1], abi.encode(poolKey.currency0, ActionConstants.OPEN_DELTA, false));
    //     assertEq(params[2], abi.encode(poolKey.currency1, ActionConstants.OPEN_DELTA, false));

    //     assertEq(
    //         params[3],
    //         abi.encode(
    //             poolKey,
    //             bounds.lowerTick,
    //             bounds.upperTick,
    //             oneSidedLiquidity,
    //             useAmountInCurrency1 ? 0 : amount,
    //             useAmountInCurrency1 ? amount : 0,
    //             address(3),
    //             ParamsBuilder.ZERO_BYTES
    //         )
    //     );

    //     assertEq(
    //         params[4], abi.encode(useAmountInCurrency1 ? poolKey.currency1 : poolKey.currency0, ActionConstants.OPEN_DELTA, false)
    //     );
    // }

    function test_truncateParams_succeeds() public view {
        bytes[] memory params = new bytes[](ParamsBuilder.FULL_RANGE_WITH_ONE_SIDED_SIZE);
        assertEq(params.length, ParamsBuilder.FULL_RANGE_WITH_ONE_SIDED_SIZE);

        bytes[] memory truncatedParams = testHelper.truncateParams(params);
        assertEq(truncatedParams.length, ParamsBuilder.FULL_RANGE_SIZE);
    }
}
