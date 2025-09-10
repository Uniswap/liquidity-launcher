// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TokenPricing} from "../../src/libraries/TokenPricing.sol";
import "forge-std/Test.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Math} from "@openzeppelin-latest/contracts/utils/math/Math.sol";

// Wrapper contract to test internal library functions
contract TokenPricingWrapper {
    function convertPrice(uint256 price, bool currencyIsCurrency0)
        external
        pure
        returns (uint256 priceX192, uint160 sqrtPriceX96)
    {
        return TokenPricing.convertPrice(price, currencyIsCurrency0);
    }
}

contract TokenPricingTest is Test {
    TokenPricingWrapper wrapper;

    function setUp() public {
        wrapper = new TokenPricingWrapper();
    }

    function test_convertPrice_revertsWithInvalidPrice() public {
        vm.expectRevert(abi.encodeWithSelector(TokenPricing.InvalidPrice.selector, 0));
        wrapper.convertPrice(0, true);
    }

    function test_fuzz_convertPrice(uint256 price, bool currencyIsCurrency0) public {
        uint256 priceX192;
        uint160 sqrtPriceX96;
        if (price == 0) {
            vm.expectRevert(abi.encodeWithSelector(TokenPricing.InvalidPrice.selector, price));
            wrapper.convertPrice(price, currencyIsCurrency0);
        } else if (price > type(uint160).max && !currencyIsCurrency0) {
            vm.expectRevert(abi.encodeWithSelector(TokenPricing.InvalidPrice.selector, price));
            wrapper.convertPrice(price, currencyIsCurrency0);
        } else if (currencyIsCurrency0) {
            uint256 newPrice = FullMath.mulDiv(1 << FixedPoint96.RESOLUTION, 1 << FixedPoint96.RESOLUTION, price);
            if (newPrice > type(uint160).max) {
                vm.expectRevert(abi.encodeWithSelector(TokenPricing.InvalidPrice.selector, newPrice));
                wrapper.convertPrice(price, currencyIsCurrency0);
            }
        } else {
            priceX192 = price << FixedPoint96.RESOLUTION;
            sqrtPriceX96 = uint160(Math.sqrt(priceX192));
            if (sqrtPriceX96 < TickMath.MIN_SQRT_PRICE || sqrtPriceX96 > TickMath.MAX_SQRT_PRICE) {
                vm.expectRevert(abi.encodeWithSelector(TokenPricing.InvalidPrice.selector, price));
                wrapper.convertPrice(price, currencyIsCurrency0);
            } else {
                wrapper.convertPrice(price, currencyIsCurrency0);
                (uint256 returnedPriceX192, uint160 returnedSqrtPriceX96) =
                    wrapper.convertPrice(price, currencyIsCurrency0);
                assertEq(returnedPriceX192, priceX192);
                assertEq(returnedSqrtPriceX96, sqrtPriceX96);
                assertGt(priceX192, price);
            }
        }
    }
}
