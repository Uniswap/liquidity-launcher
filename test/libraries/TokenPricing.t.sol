// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {FixedPoint96} from '@uniswap/v4-core/src/libraries/FixedPoint96.sol';
import {FullMath} from '@uniswap/v4-core/src/libraries/FullMath.sol';
import {TickMath} from '@uniswap/v4-core/src/libraries/TickMath.sol';
import 'forge-std/Test.sol';
import {TokenPricing} from 'src/libraries/TokenPricing.sol';

contract TokenPricingHelper is Test {
    function convertToPriceX192(uint256 price, bool currencyIsCurrency0) public pure returns (uint256 priceX192) {
        return TokenPricing.convertToPriceX192(price, currencyIsCurrency0);
    }

    function convertToSqrtPriceX96(uint256 priceX192) public pure returns (uint160 sqrtPriceX96) {
        return TokenPricing.convertToSqrtPriceX96(priceX192);
    }

    function calculateAmounts(
        uint256 priceX192,
        uint128 currencyAmount,
        bool currencyIsCurrency0,
        uint128 reserveTokenAmount
    ) public pure returns (uint128 tokenAmount, uint128 correspondingCurrencyAmount) {
        return TokenPricing.calculateAmounts(priceX192, currencyAmount, currencyIsCurrency0, reserveTokenAmount);
    }
}

contract TokenPricingTest is Test {
    uint256 constant Q192 = 2 ** 192;
    TokenPricingHelper public tokenPricingHelper;

    function setUp() public {
        tokenPricingHelper = new TokenPricingHelper();
    }

    function test_convertToPriceX192_currencyIsCurrency0_succeeds() public view {
        uint256 price = 1e18;
        bool currencyIsCurrency0 = true;
        uint256 priceX192 = tokenPricingHelper.convertToPriceX192(price, currencyIsCurrency0);
        assertEq(priceX192, FullMath.mulDiv(1 << 192, FixedPoint96.Q96, price));
    }

    function test_convertToPriceX192_currencyIsCurrency1_succeeds() public view {
        uint256 price = 1e18;
        bool currencyIsCurrency0 = false;
        uint256 priceX192 = tokenPricingHelper.convertToPriceX192(price, currencyIsCurrency0);
        assertEq(priceX192, 1e18 << 96);
    }

    function test_fuzz_convertToPriceX192_succeeds(uint256 price, bool currencyIsCurrency0) public {
        if (price == 0) {
            vm.expectRevert(abi.encodeWithSelector(TokenPricing.PriceIsZero.selector, price));
            tokenPricingHelper.convertToPriceX192(price, currencyIsCurrency0);
        } else {
            if (currencyIsCurrency0) {
                if ((1 << 192) / price > type(uint160).max) {
                    vm.expectRevert(
                        abi.encodeWithSelector(
                            TokenPricing.PriceTooHigh.selector, (1 << 192) / price, type(uint160).max
                        )
                    );
                    tokenPricingHelper.convertToPriceX192(price, currencyIsCurrency0);
                } else {
                    uint256 priceX192 = tokenPricingHelper.convertToPriceX192(price, currencyIsCurrency0);
                    assertEq(priceX192, FullMath.mulDiv(1 << 192, FixedPoint96.Q96, price));
                }
            } else {
                if (price > type(uint160).max) {
                    vm.expectRevert(
                        abi.encodeWithSelector(TokenPricing.PriceTooHigh.selector, price, type(uint160).max)
                    );
                    tokenPricingHelper.convertToPriceX192(price, currencyIsCurrency0);
                } else {
                    uint256 priceX192 = tokenPricingHelper.convertToPriceX192(price, currencyIsCurrency0);
                    assertEq(priceX192, price << 96);
                }
            }
        }
    }

    function test_fuzz_convertToSqrtPriceX96_succeeds(uint256 priceX192) public {
        uint160 sqrtPriceX96 = uint160(Math.sqrt(priceX192));
        if (sqrtPriceX96 < TickMath.MIN_SQRT_PRICE || sqrtPriceX96 > TickMath.MAX_SQRT_PRICE) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    TokenPricing.SqrtPriceX96OutOfBounds.selector,
                    sqrtPriceX96,
                    TickMath.MIN_SQRT_PRICE,
                    TickMath.MAX_SQRT_PRICE
                )
            );
            tokenPricingHelper.convertToSqrtPriceX96(priceX192);
        } else {
            uint160 sqrtP = tokenPricingHelper.convertToSqrtPriceX96(priceX192);
            assertEq(sqrtPriceX96, sqrtP);
        }
    }

    function test_convertToSqrtPriceX96_succeeds() public view {
        // Test 1:1 price
        uint256 priceX192 = FullMath.mulDiv(1e18, Q192, 1e18);
        uint160 sqrtPriceX96 = tokenPricingHelper.convertToSqrtPriceX96(priceX192);
        assertEq(sqrtPriceX96, 79_228_162_514_264_337_593_543_950_336);

        // Test 100:1 price
        priceX192 = FullMath.mulDiv(100e18, Q192, 1e18);
        sqrtPriceX96 = tokenPricingHelper.convertToSqrtPriceX96(priceX192);
        assertEq(sqrtPriceX96, 792_281_625_142_643_375_935_439_503_360);

        // Test 1:100 price
        priceX192 = FullMath.mulDiv(1e18, Q192, 100e18);
        sqrtPriceX96 = tokenPricingHelper.convertToSqrtPriceX96(priceX192);
        assertEq(sqrtPriceX96, 7_922_816_251_426_433_759_354_395_033);

        // Test arbitrary price (111:333)
        priceX192 = FullMath.mulDiv(111e18, Q192, 333e18);
        sqrtPriceX96 = tokenPricingHelper.convertToSqrtPriceX96(priceX192);
        assertEq(sqrtPriceX96, 45_742_400_955_009_932_534_161_870_629);

        // Test inverse (333:111)
        priceX192 = FullMath.mulDiv(333e18, Q192, 111e18);
        sqrtPriceX96 = tokenPricingHelper.convertToSqrtPriceX96(priceX192);
        assertEq(sqrtPriceX96, 137_227_202_865_029_797_602_485_611_888);
    }
}
