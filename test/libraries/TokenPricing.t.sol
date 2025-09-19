// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {TokenPricing} from "../../src/libraries/TokenPricing.sol";
import {InverseHelpers} from "../shared/InverseHelpers.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Math} from "@openzeppelin-latest/contracts/utils/math/Math.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

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
        uint128 reserveSupply
    ) public pure returns (uint128 tokenAmount, uint128 leftoverCurrency, uint128 correspondingCurrencyAmount) {
        return TokenPricing.calculateAmounts(priceX192, currencyAmount, currencyIsCurrency0, reserveSupply);
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
        assertEq(priceX192, InverseHelpers.inverseQ96(price) << 96);
    }

    function test_convertToPriceX192_currencyIsCurrency1_succeeds() public view {
        uint256 price = 1e18;
        bool currencyIsCurrency0 = false;
        uint256 priceX192 = tokenPricingHelper.convertToPriceX192(price, currencyIsCurrency0);
        assertEq(priceX192, 1e18 << 96);
    }

    function test_fuzz_convertToPriceX192_succeeds(uint256 price, bool currencyIsCurrency0) public {
        if (price == 0) {
            vm.expectRevert(abi.encodeWithSelector(TokenPricing.InvalidPrice.selector, price));
            tokenPricingHelper.convertToPriceX192(price, currencyIsCurrency0);
        } else {
            if (currencyIsCurrency0) {
                if ((1 << 192) / price > type(uint160).max) {
                    vm.expectRevert(abi.encodeWithSelector(TokenPricing.InvalidPrice.selector, (1 << 192) / price));
                    tokenPricingHelper.convertToPriceX192(price, currencyIsCurrency0);
                } else {
                    uint256 priceX192 = tokenPricingHelper.convertToPriceX192(price, currencyIsCurrency0);
                    assertEq(priceX192, InverseHelpers.inverseQ96(price) << 96);
                }
            } else {
                if (price > type(uint160).max) {
                    vm.expectRevert(abi.encodeWithSelector(TokenPricing.InvalidPrice.selector, price));
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
            vm.expectRevert();
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
        assertEq(sqrtPriceX96, 79228162514264337593543950336);

        // Test 100:1 price
        priceX192 = FullMath.mulDiv(100e18, Q192, 1e18);
        sqrtPriceX96 = tokenPricingHelper.convertToSqrtPriceX96(priceX192);
        assertEq(sqrtPriceX96, 792281625142643375935439503360);

        // Test 1:100 price
        priceX192 = FullMath.mulDiv(1e18, Q192, 100e18);
        sqrtPriceX96 = tokenPricingHelper.convertToSqrtPriceX96(priceX192);
        assertEq(sqrtPriceX96, 7922816251426433759354395033);

        // Test arbitrary price (111:333)
        priceX192 = FullMath.mulDiv(111e18, Q192, 333e18);
        sqrtPriceX96 = tokenPricingHelper.convertToSqrtPriceX96(priceX192);
        assertEq(sqrtPriceX96, 45742400955009932534161870629);

        // Test inverse (333:111)
        priceX192 = FullMath.mulDiv(333e18, Q192, 111e18);
        sqrtPriceX96 = tokenPricingHelper.convertToSqrtPriceX96(priceX192);
        assertEq(sqrtPriceX96, 137227202865029797602485611888);
    }
}
