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

// Test helper contract to expose internal library functions for testing
contract ParamsBuilderTestHelper {
    using ParamsBuilder for *;

    function buildFullRangeParams(
        FullRangeParams memory fullRangeParams,
        PoolKey memory poolKey,
        TickBounds memory bounds,
        bool currencyIsCurrency0,
        uint256 paramsArraySize,
        address positionRecipient
    ) external pure returns (bytes[] memory) {
        return ParamsBuilder.buildFullRangeParams(
            fullRangeParams, poolKey, bounds, currencyIsCurrency0, paramsArraySize, positionRecipient
        );
    }

    function buildOneSidedParams(
        OneSidedParams memory oneSidedParams,
        PoolKey memory poolKey,
        TickBounds memory bounds,
        bool currencyIsCurrency0,
        bytes[] memory existingParams,
        address positionRecipient
    ) external pure returns (bytes[] memory) {
        return ParamsBuilder.buildOneSidedParams(
            oneSidedParams, poolKey, bounds, currencyIsCurrency0, existingParams, positionRecipient
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
            address(3)
        );
    }

    function test_buildFullRangeParams_succeeds() public view {
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
            ParamsBuilder.FULL_RANGE_SIZE,
            address(3)
        );
        assertEq(params.length, ParamsBuilder.FULL_RANGE_SIZE);
        assertEq(params[0], abi.encode(Currency.wrap(address(0)), 100e18, false));
        assertEq(params[1], abi.encode(Currency.wrap(address(1)), 10e18, false));
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
                100e18,
                10e18,
                address(3),
                ParamsBuilder.ZERO_BYTES
            )
        );
        assertEq(params[3], abi.encode(Currency.wrap(address(0)), type(uint256).max));
        assertEq(params[4], abi.encode(Currency.wrap(address(1)), type(uint256).max));
    }

    function test_fuzz_buildFullRangeParams_succeeds(
        PoolKey memory poolKey,
        TickBounds memory bounds,
        bool currencyIsCurrency0,
        uint128 tokenAmount,
        uint128 currencyAmount
    ) public view {
        bytes[] memory params = testHelper.buildFullRangeParams(
            FullRangeParams({tokenAmount: tokenAmount, currencyAmount: currencyAmount}),
            poolKey,
            bounds,
            currencyIsCurrency0,
            ParamsBuilder.FULL_RANGE_SIZE,
            address(3)
        );

        assertEq(params.length, ParamsBuilder.FULL_RANGE_SIZE);
        assertEq(params[0], abi.encode(poolKey.currency0, currencyIsCurrency0 ? currencyAmount : tokenAmount, false));
        assertEq(params[1], abi.encode(poolKey.currency1, currencyIsCurrency0 ? tokenAmount : currencyAmount, false));
        assertEq(
            params[2],
            abi.encode(
                poolKey,
                bounds.lowerTick,
                bounds.upperTick,
                currencyIsCurrency0 ? currencyAmount : tokenAmount,
                currencyIsCurrency0 ? tokenAmount : currencyAmount,
                address(3),
                ParamsBuilder.ZERO_BYTES
            )
        );
        assertEq(params[3], abi.encode(poolKey.currency0, type(uint256).max));
        assertEq(params[4], abi.encode(poolKey.currency1, type(uint256).max));
    }

    function test_buildOneSidedParams_revertsWithInvalidParamsLength() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ParamsBuilder.InvalidParamsLength.selector, ParamsBuilder.FULL_RANGE_WITH_ONE_SIDED_SIZE - 1
            )
        );
        testHelper.buildOneSidedParams(
            OneSidedParams({amount: 10e18, existingPoolLiquidity: 100e18, inToken: true}),
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
            address(3)
        );
    }

    function test_buildOneSidedParams_inToken_succeeds() public view {
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
            ParamsBuilder.FULL_RANGE_WITH_ONE_SIDED_SIZE,
            address(3)
        );

        bytes[] memory params = testHelper.buildOneSidedParams(
            OneSidedParams({amount: 10e18, existingPoolLiquidity: 100e18, inToken: true}),
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
            address(3)
        );
        assertEq(params.length, ParamsBuilder.FULL_RANGE_WITH_ONE_SIDED_SIZE);
        assertEq(params[0], abi.encode(Currency.wrap(address(0)), 100e18, false));
        assertEq(params[1], abi.encode(Currency.wrap(address(1)), 10e18, false));
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
                100e18,
                10e18,
                address(3),
                ParamsBuilder.ZERO_BYTES
            )
        );
        assertEq(params[3], abi.encode(Currency.wrap(address(0)), type(uint256).max));
        assertEq(params[4], abi.encode(Currency.wrap(address(1)), type(uint256).max));
        assertEq(params[5], abi.encode(Currency.wrap(address(1)), 10e18, false));
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
                TickMath.MAX_TICK,
                0,
                10e18,
                address(3),
                ParamsBuilder.ZERO_BYTES
            )
        );
        assertEq(params[7], abi.encode(Currency.wrap(address(1)), type(uint256).max));
    }

    function test_buildOneSidedParams_inCurrency_succeeds() public view {
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
            ParamsBuilder.FULL_RANGE_WITH_ONE_SIDED_SIZE,
            address(3)
        );

        bytes[] memory params = testHelper.buildOneSidedParams(
            OneSidedParams({amount: 10e18, existingPoolLiquidity: 100e18, inToken: false}),
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
            address(3)
        );
        assertEq(params.length, ParamsBuilder.FULL_RANGE_WITH_ONE_SIDED_SIZE);
        assertEq(params[0], abi.encode(Currency.wrap(address(0)), 100e18, false));
        assertEq(params[1], abi.encode(Currency.wrap(address(1)), 10e18, false));
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
                100e18,
                10e18,
                address(3),
                ParamsBuilder.ZERO_BYTES
            )
        );
        assertEq(params[3], abi.encode(Currency.wrap(address(0)), type(uint256).max));
        assertEq(params[4], abi.encode(Currency.wrap(address(1)), type(uint256).max));
        assertEq(params[5], abi.encode(Currency.wrap(address(0)), 10e18, false));
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
                TickMath.MAX_TICK,
                10e18,
                0,
                address(3),
                ParamsBuilder.ZERO_BYTES
            )
        );
        assertEq(params[7], abi.encode(Currency.wrap(address(0)), type(uint256).max));
    }

    function test_fuzz_buildOneSidedParams_succeeds(
        PoolKey memory poolKey,
        TickBounds memory bounds,
        bool currencyIsCurrency0,
        uint128 amount,
        uint128 tokenAmount,
        uint128 currencyAmount,
        bool inToken
    ) public view {
        bytes[] memory fullRangeParams = testHelper.buildFullRangeParams(
            FullRangeParams({tokenAmount: tokenAmount, currencyAmount: currencyAmount}),
            poolKey,
            bounds,
            currencyIsCurrency0,
            ParamsBuilder.FULL_RANGE_WITH_ONE_SIDED_SIZE,
            address(3)
        );
        bytes[] memory params = testHelper.buildOneSidedParams(
            OneSidedParams({amount: amount, existingPoolLiquidity: 100e18, inToken: inToken}),
            poolKey,
            bounds,
            currencyIsCurrency0,
            fullRangeParams,
            address(3)
        );

        assertEq(params.length, ParamsBuilder.FULL_RANGE_WITH_ONE_SIDED_SIZE);
        assertEq(params[0], abi.encode(poolKey.currency0, currencyIsCurrency0 ? currencyAmount : tokenAmount, false));
        assertEq(params[1], abi.encode(poolKey.currency1, currencyIsCurrency0 ? tokenAmount : currencyAmount, false));
        assertEq(
            params[2],
            abi.encode(
                poolKey,
                bounds.lowerTick,
                bounds.upperTick,
                currencyIsCurrency0 ? currencyAmount : tokenAmount,
                currencyIsCurrency0 ? tokenAmount : currencyAmount,
                address(3),
                ParamsBuilder.ZERO_BYTES
            )
        );
        assertEq(params[3], abi.encode(poolKey.currency0, type(uint256).max));
        assertEq(params[4], abi.encode(poolKey.currency1, type(uint256).max));
        assertEq(
            params[5], abi.encode(currencyIsCurrency0 == inToken ? poolKey.currency1 : poolKey.currency0, amount, false)
        );
        assertEq(
            params[6],
            abi.encode(
                poolKey,
                bounds.lowerTick,
                bounds.upperTick,
                currencyIsCurrency0 == inToken ? 0 : amount,
                currencyIsCurrency0 == inToken ? amount : 0,
                address(3),
                ParamsBuilder.ZERO_BYTES
            )
        );
        assertEq(
            params[7],
            abi.encode(currencyIsCurrency0 == inToken ? poolKey.currency1 : poolKey.currency0, type(uint256).max)
        );
    }

    function test_truncateParams_succeeds() public view {
        bytes[] memory params = new bytes[](ParamsBuilder.FULL_RANGE_WITH_ONE_SIDED_SIZE);
        assertEq(params.length, ParamsBuilder.FULL_RANGE_WITH_ONE_SIDED_SIZE);

        bytes[] memory truncatedParams = testHelper.truncateParams(params);
        assertEq(truncatedParams.length, ParamsBuilder.FULL_RANGE_SIZE);
    }
}
