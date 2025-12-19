// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ParamsBuilder} from "src/libraries/ParamsBuilder.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickBounds} from "src/types/PositionTypes.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

// Test helper contract to expose internal library functions for testing
contract ParamsBuilderTestHelper {
    using ParamsBuilder for *;

    function addMintParam(
        PoolKey memory poolKey,
        TickBounds memory bounds,
        uint128 liquidity,
        uint128 tokenAmount,
        uint128 currencyAmount,
        address positionRecipient
    ) external pure returns (bytes memory) {
        return ParamsBuilder.addMintParam(poolKey, bounds, liquidity, tokenAmount, currencyAmount, positionRecipient);
    }

    function addSettleParam(address currency) external pure returns (bytes memory) {
        return ParamsBuilder.addSettleParam(currency);
    }

    function addTakePairParam(address currency0, address currency1) external view returns (bytes memory) {
        return ParamsBuilder.addTakePairParam(currency0, currency1);
    }
}

contract ParamsBuilderTest is Test {
    ParamsBuilderTestHelper testHelper;

    using SafeCast for uint256;

    function setUp() public {
        testHelper = new ParamsBuilderTestHelper();
    }

    function test_addMintParam_succeeds() public view {
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            TickMath.getSqrtPriceAtTick(0),
            TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK),
            TickMath.getSqrtPriceAtTick(TickMath.MAX_TICK),
            100e18,
            10e18
        );
        bytes memory param = testHelper.addMintParam(
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(address(1)),
                fee: 10000,
                tickSpacing: 1,
                hooks: IHooks(address(0))
            }),
            TickBounds({lowerTick: TickMath.MIN_TICK, upperTick: TickMath.MAX_TICK}),
            liquidity,
            10e18,
            100e18,
            address(3)
        );
        assertEq(
            param,
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
    }

    function test_fuzz_addMintParam_succeeds(
        PoolKey memory poolKey,
        TickBounds memory bounds,
        bool currencyIsCurrency0,
        uint128 tokenAmount,
        uint128 currencyAmount
    ) public view {
        if (_shouldRevertOnLiquidity(currencyIsCurrency0, tokenAmount, currencyAmount)) {
            return;
        }
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            TickMath.getSqrtPriceAtTick(0),
            TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK),
            TickMath.getSqrtPriceAtTick(TickMath.MAX_TICK),
            currencyIsCurrency0 ? currencyAmount : tokenAmount,
            currencyIsCurrency0 ? tokenAmount : currencyAmount
        );
        bytes memory param =
            testHelper.addMintParam(poolKey, bounds, liquidity, tokenAmount, currencyAmount, address(3));

        bool actualCurrencyIsCurrency0 = poolKey.currency0 < poolKey.currency1;
        assertEq(
            param,
            abi.encode(
                poolKey,
                bounds.lowerTick,
                bounds.upperTick,
                liquidity,
                actualCurrencyIsCurrency0 ? currencyAmount : tokenAmount,
                actualCurrencyIsCurrency0 ? tokenAmount : currencyAmount,
                address(3),
                ParamsBuilder.ZERO_BYTES
            )
        );
    }

    function test_addMintParam_inToken_succeeds() public view {
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            TickMath.getSqrtPriceAtTick(0),
            TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK),
            TickMath.getSqrtPriceAtTick(TickMath.MAX_TICK),
            100e18,
            10e18
        );
        bytes memory fullRangeParam = testHelper.addMintParam(
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(address(1)),
                fee: 10000,
                tickSpacing: 1,
                hooks: IHooks(address(0))
            }),
            TickBounds({lowerTick: TickMath.MIN_TICK, upperTick: TickMath.MAX_TICK}),
            liquidity,
            10e18,
            100e18,
            address(3)
        );

        uint128 oneSidedLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            TickMath.getSqrtPriceAtTick(0),
            TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK),
            TickMath.getSqrtPriceAtTick(0),
            0,
            10e18
        );

        bytes memory oneSidedParam = testHelper.addMintParam(
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(address(1)),
                fee: 10000,
                tickSpacing: 1,
                hooks: IHooks(address(0))
            }),
            TickBounds({lowerTick: TickMath.MIN_TICK, upperTick: TickMath.MAX_TICK}),
            oneSidedLiquidity,
            10e18,
            0,
            address(3)
        );

        assertEq(
            fullRangeParam,
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

        assertEq(
            oneSidedParam,
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

    function test_addMintParam_inCurrency_succeeds() public view {
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            TickMath.getSqrtPriceAtTick(0),
            TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK),
            TickMath.getSqrtPriceAtTick(TickMath.MAX_TICK),
            100e18,
            10e18
        );
        bytes memory fullRangeParam = testHelper.addMintParam(
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(address(1)),
                fee: 10000,
                tickSpacing: 1,
                hooks: IHooks(address(0))
            }),
            TickBounds({lowerTick: TickMath.MIN_TICK, upperTick: TickMath.MAX_TICK}),
            liquidity,
            10e18,
            100e18,
            address(3)
        );

        uint128 oneSidedLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            TickMath.getSqrtPriceAtTick(0),
            TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK),
            TickMath.getSqrtPriceAtTick(0),
            0,
            10e18
        );
        bytes memory oneSidedParam = testHelper.addMintParam(
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(address(1)),
                fee: 10000,
                tickSpacing: 1,
                hooks: IHooks(address(0))
            }),
            TickBounds({lowerTick: TickMath.MIN_TICK, upperTick: TickMath.MAX_TICK}),
            oneSidedLiquidity,
            0,
            10e18,
            address(3)
        );

        assertEq(
            fullRangeParam,
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

        assertEq(
            oneSidedParam,
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

    function test_fuzz_addMintParam_withOneSided_succeeds(
        PoolKey memory poolKey,
        TickBounds memory bounds,
        uint128 tokenAmount,
        uint128 currencyAmount
    ) public view {
        bool currencyIsCurrency0 = poolKey.currency0 < poolKey.currency1;
        bool inToken = tokenAmount > currencyAmount;
        bool useAmountInCurrency1 = currencyIsCurrency0 == inToken;
        if (_shouldRevertOnLiquidity(currencyIsCurrency0, tokenAmount, currencyAmount)) {
            return;
        }
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            TickMath.getSqrtPriceAtTick(0),
            TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK),
            TickMath.getSqrtPriceAtTick(TickMath.MAX_TICK),
            currencyIsCurrency0 ? currencyAmount : tokenAmount,
            currencyIsCurrency0 ? tokenAmount : currencyAmount
        );
        bytes memory fullRangeParam =
            testHelper.addMintParam(poolKey, bounds, liquidity, tokenAmount, currencyAmount, address(3));
        uint128 oneSidedLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            TickMath.getSqrtPriceAtTick(0),
            TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK),
            TickMath.getSqrtPriceAtTick(0),
            0,
            10e18
        );
        bytes memory oneSidedParam = testHelper.addMintParam(
            poolKey,
            bounds,
            oneSidedLiquidity,
            useAmountInCurrency1 ? 0 : 10e18,
            useAmountInCurrency1 ? 10e18 : 0,
            address(3)
        );

        assertEq(
            fullRangeParam,
            abi.encode(
                poolKey,
                bounds.lowerTick,
                bounds.upperTick,
                liquidity,
                currencyIsCurrency0 ? currencyAmount : tokenAmount,
                currencyIsCurrency0 ? tokenAmount : currencyAmount,
                address(3),
                ParamsBuilder.ZERO_BYTES
            )
        );

        assertEq(
            oneSidedParam,
            abi.encode(
                poolKey,
                bounds.lowerTick,
                bounds.upperTick,
                oneSidedLiquidity,
                useAmountInCurrency1 ? 0 : 10e18,
                useAmountInCurrency1 ? 10e18 : 0,
                address(3),
                ParamsBuilder.ZERO_BYTES
            )
        );
    }

    function test_addSettleParam_succeeds(address currencyAddress) public view {
        bytes memory param = testHelper.addSettleParam(currencyAddress);

        assertEq(param, abi.encode(currencyAddress, ActionConstants.CONTRACT_BALANCE, false));
    }

    function test_fuzz_addSettleParam_succeeds(address currencyAddress) public view {
        bytes memory param = testHelper.addSettleParam(currencyAddress);

        assertEq(param, abi.encode(currencyAddress, ActionConstants.CONTRACT_BALANCE, false));
    }

    function test_addTakePairParam_withZeroAddresses_succeeds(address currency0) public view {
        address currency1 = address(0);
        bytes memory param = testHelper.addTakePairParam(currency0, currency1);

        assertEq(param, abi.encode(currency0, currency1, address(testHelper)));
    }

    function test_fuzz_addTakePairParam_succeeds(address addr0, address addr1) public view {
        bytes memory param = testHelper.addTakePairParam(addr0, addr1);

        assertEq(param, abi.encode(addr0, addr1, address(testHelper)));
    }

    // Helper function to check if liquidity calculation should revert
    function _shouldRevertOnLiquidity(bool currencyIsCurrency0, uint128 tokenAmount, uint128 currencyAmount)
        private
        view
        returns (bool)
    {
        try this.calculateLiquidity(
            TickMath.getSqrtPriceAtTick(0),
            TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK),
            TickMath.getSqrtPriceAtTick(TickMath.MAX_TICK),
            currencyIsCurrency0 ? currencyAmount : tokenAmount,
            currencyIsCurrency0 ? tokenAmount : currencyAmount
        ) returns (
            uint128
        ) {
            return false;
        } catch {
            return true;
        }
    }

    function calculateLiquidity(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint256 amount0,
        uint256 amount1
    ) external pure returns (uint128 liquidity) {
        if (sqrtPriceAX96 > sqrtPriceBX96) {
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        }

        if (sqrtPriceX96 <= sqrtPriceAX96) {
            liquidity = getLiquidityForAmount0(sqrtPriceAX96, sqrtPriceBX96, amount0);
        } else if (sqrtPriceX96 < sqrtPriceBX96) {
            uint128 liquidity0 = getLiquidityForAmount0(sqrtPriceX96, sqrtPriceBX96, amount0);
            uint128 liquidity1 = getLiquidityForAmount1(sqrtPriceAX96, sqrtPriceX96, amount1);

            liquidity = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
        } else {
            liquidity = getLiquidityForAmount1(sqrtPriceAX96, sqrtPriceBX96, amount1);
        }

        return liquidity;
    }

    function getLiquidityForAmount0(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint256 amount0)
        internal
        pure
        returns (uint128)
    {
        unchecked {
            if (sqrtPriceAX96 > sqrtPriceBX96) (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
            uint256 intermediate = FullMath.mulDiv(sqrtPriceAX96, sqrtPriceBX96, FixedPoint96.Q96);
            uint128 liquidity = FullMath.mulDiv(amount0, intermediate, sqrtPriceBX96 - sqrtPriceAX96).toUint128();
            return liquidity;
        }
    }

    function getLiquidityForAmount1(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint256 amount1)
        internal
        pure
        returns (uint128)
    {
        unchecked {
            if (sqrtPriceAX96 > sqrtPriceBX96) (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
            uint128 liquidity = FullMath.mulDiv(amount1, FixedPoint96.Q96, sqrtPriceBX96 - sqrtPriceAX96).toUint128();
            return liquidity;
        }
    }
}
