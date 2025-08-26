// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {LBPStrategyBasicTestBase} from "./base/LBPStrategyBasicTestBase.sol";
import {ISubscriber} from "../../src/interfaces/ISubscriber.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {MathHelpers} from "../shared/MathHelpers.t.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

contract LBPStrategyBasicPricingTest is LBPStrategyBasicTestBase {
    // ============ Access Control Tests ============

    function test_onNotify_revertsWithOnlyAuctionCanSetPrice() public {
        vm.expectRevert(
            abi.encodeWithSelector(ISubscriber.OnlyAuctionCanSetPrice.selector, address(lbp.auction()), address(this))
        );
        lbp.onNotify(abi.encode(TickMath.getSqrtPriceAtTick(0), DEFAULT_TOTAL_SUPPLY, DEFAULT_TOTAL_SUPPLY));
    }

    // ============ ETH Currency Tests ============

    function test_onNotify_revertsWithInvalidCurrencyAmount() public {
        // Setup: Send tokens to LBP and create auction
        sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

        uint128 expectedAmount = DEFAULT_TOTAL_SUPPLY / 2;
        uint128 sentAmount = expectedAmount - 1;

        vm.deal(address(lbp.auction()), sentAmount);
        vm.prank(address(lbp.auction()));
        vm.expectRevert(abi.encodeWithSelector(ISubscriber.InvalidCurrencyAmount.selector, sentAmount, expectedAmount));
        lbp.onNotify{value: sentAmount}(abi.encode(TickMath.getSqrtPriceAtTick(0), expectedAmount, expectedAmount));
    }

    function test_onNotify_withETH_succeeds() public {
        // Setup: Send tokens to LBP and create auction
        sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

        uint128 tokenAmount = DEFAULT_TOTAL_SUPPLY / 2;
        uint128 ethAmount = DEFAULT_TOTAL_SUPPLY / 2;

        vm.deal(address(lbp.auction()), ethAmount);

        uint256 priceX192 = FullMath.mulDiv(tokenAmount, 2 ** 192, ethAmount);
        uint160 expectedSqrtPrice = uint160(Math.sqrt(priceX192));

        vm.expectEmit(true, false, false, true);
        emit Notified(abi.encode(priceX192, tokenAmount, ethAmount));

        vm.prank(address(lbp.auction()));
        lbp.onNotify{value: ethAmount}(abi.encode(priceX192, tokenAmount, ethAmount));

        // Verify state
        assertEq(lbp.initialSqrtPriceX96(), expectedSqrtPrice);
        assertEq(lbp.initialTokenAmount(), tokenAmount);
        assertEq(lbp.initialCurrencyAmount(), ethAmount);
        assertEq(address(lbp).balance, ethAmount);
    }

    function test_onNotify_revertsWithNonETHCurrencyCannotReceiveETH() public {
        // Setup with DAI as currency
        setupWithCurrency(DAI);

        // Send tokens to LBP
        sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

        // Give auction DAI
        deal(DAI, address(lbp.auction()), 1_000e18);

        // Give auction ETH to try sending
        vm.deal(address(lbp.auction()), 1e18);

        vm.prank(address(lbp.auction()));
        vm.expectRevert(abi.encodeWithSelector(ISubscriber.NonETHCurrencyCannotReceiveETH.selector, DAI));
        lbp.onNotify{value: 1e18}(abi.encode(TickMath.getSqrtPriceAtTick(0), DEFAULT_TOTAL_SUPPLY, 1e18));
    }

    function test_onNotify_revertsWithInvalidLiquidity() public {
        setupWithSupply(type(uint128).max);
        sendTokensToLBP(address(tokenLauncher), token, lbp, type(uint128).max);
        uint128 tokenAmount = type(uint128).max / 2;
        uint128 ethAmount = type(uint128).max;
        vm.deal(address(lbp.auction()), ethAmount);
        uint256 priceX192 = FullMath.mulDiv(tokenAmount, 2 ** 192, ethAmount);
        uint128 maxLiquidity = MathHelpers.tickSpacingToMaxLiquidityPerTick(lbp.poolTickSpacing());
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            uint160(Math.sqrt(priceX192)),
            TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK / lbp.poolTickSpacing() * lbp.poolTickSpacing()),
            TickMath.getSqrtPriceAtTick(TickMath.MAX_TICK / lbp.poolTickSpacing() * lbp.poolTickSpacing()),
            ethAmount,
            tokenAmount
        );
        vm.prank(address(lbp.auction()));
        vm.expectRevert(abi.encodeWithSelector(ISubscriber.InvalidLiquidity.selector, maxLiquidity, liquidity));
        lbp.onNotify{value: ethAmount}(abi.encode(priceX192, tokenAmount, ethAmount));
    }

    // ============ Non-ETH Currency Tests ============

    function test_onNotify_withNonETHCurrency_succeeds() public {
        // Setup with DAI as currency
        setupWithCurrency(DAI);

        // Send tokens to LBP
        sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

        uint128 tokenAmount = DEFAULT_TOTAL_SUPPLY / 2;
        uint128 daiAmount = DEFAULT_TOTAL_SUPPLY / 2;

        // Setup DAI for auction
        deal(DAI, address(lbp.auction()), daiAmount);

        vm.prank(address(lbp.auction()));
        ERC20(DAI).approve(address(lbp), daiAmount);

        uint256 priceX192 = FullMath.mulDiv(tokenAmount, 2 ** 192, daiAmount);
        uint160 expectedSqrtPrice = uint160(Math.sqrt(priceX192));

        vm.expectEmit(true, false, false, true);
        emit Notified(abi.encode(priceX192, tokenAmount, daiAmount));

        vm.prank(address(lbp.auction()));
        lbp.onNotify(abi.encode(priceX192, tokenAmount, daiAmount));

        // Verify state
        assertEq(lbp.initialSqrtPriceX96(), expectedSqrtPrice);
        assertEq(lbp.initialTokenAmount(), tokenAmount);
        assertEq(lbp.initialCurrencyAmount(), daiAmount);

        // Verify balances
        assertEq(ERC20(DAI).balanceOf(address(lbp.auction())), 0);
        assertEq(ERC20(DAI).balanceOf(address(lbp)), daiAmount);
    }

    // ============ Price Calculation Tests ============

    function test_priceCalculations() public pure {
        // Test 1:1 price
        uint256 priceX192 = FullMath.mulDiv(1e18, 2 ** 192, 1e18);
        uint160 sqrtPriceX96 = uint160(Math.sqrt(priceX192));
        assertEq(sqrtPriceX96, 79228162514264337593543950336);

        // Test 100:1 price
        priceX192 = FullMath.mulDiv(100e18, 2 ** 192, 1e18);
        sqrtPriceX96 = uint160(Math.sqrt(priceX192));
        assertEq(sqrtPriceX96, 792281625142643375935439503360);

        // Test 1:100 price
        priceX192 = FullMath.mulDiv(1e18, 2 ** 192, 100e18);
        sqrtPriceX96 = uint160(Math.sqrt(priceX192));
        assertEq(sqrtPriceX96, 7922816251426433759354395033);

        // Test arbitrary price (111:333)
        priceX192 = FullMath.mulDiv(111e18, 2 ** 192, 333e18);
        sqrtPriceX96 = uint160(Math.sqrt(priceX192));
        assertEq(sqrtPriceX96, 45742400955009932534161870629);

        // Test inverse (333:111)
        priceX192 = FullMath.mulDiv(333e18, 2 ** 192, 111e18);
        sqrtPriceX96 = uint160(Math.sqrt(priceX192));
        assertEq(sqrtPriceX96, 137227202865029797602485611888);
    }

    function test_priceCalculationRoundTrip() public pure {
        // Example: clearingPrice of 2.0 (2 tokens per ETH) in Q96 format
        uint256 clearingPriceQ96 = 2 * (1 << 96); // 2 * 2^96
        uint128 ethAmount = 1e18; // 1 ETH

        // // Convert to Q192 for higher precision
        // uint256 priceX192 = clearingPriceQ96 << 96;

        // Calculate expected tokens: 2 tokens per ETH * 1 ETH = 2 tokens
        uint256 tokenAmount = FullMath.mulDiv(clearingPriceQ96, ethAmount, 2 ** 96);
        assertEq(tokenAmount, 2e18); // Exactly 2 tokens

        // Recover the price (should get back the original)
        uint256 recoveredPriceQ96 = FullMath.mulDiv(tokenAmount, 2 ** 96, ethAmount);
        assertEq(recoveredPriceQ96, clearingPriceQ96); // Perfect round trip!
    }

    function test_morePriceCalculations_fuzz(uint256 clearingPrice, uint128 ethAmount) public pure {
        vm.assume(ethAmount > 0);
        vm.assume(clearingPrice > 0 && clearingPrice <= type(uint160).max); // Limit to reasonable Q96 values

        // Convert Q96 to Q192
        //uint256 priceX192 = clearingPrice << 96;

        // Calculate tokenAmount (no casting yet)
        uint256 expectedTokenAmount = FullMath.mulDiv(clearingPrice, ethAmount, 2 ** 96);

        // Only proceed if tokenAmount is non-zero and fits in uint128
        vm.assume(expectedTokenAmount > 0 && expectedTokenAmount <= type(uint128).max);

        // Recover the price
        uint256 recoveredPriceQ96 = FullMath.mulDiv(expectedTokenAmount, 2 ** 96, ethAmount);

        // The maximum rounding error is proportional to 2^192 / ethAmount
        // This is because we lose up to 1 unit in the division by ethAmount
        uint256 maxError = (uint256(1) << 192) / ethAmount + 1;

        // Check that we recover the price within the expected error bound
        assertApproxEqAbs(recoveredPriceQ96, clearingPrice, maxError);
    }

    function test_onNotify_revertsWithInvalidTokenAmount() public {
        sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

        uint128 tokenAmount = DEFAULT_TOTAL_SUPPLY / 2;
        uint128 ethAmount = DEFAULT_TOTAL_SUPPLY / 2;

        vm.deal(address(lbp.auction()), ethAmount);

        uint256 priceX192 = FullMath.mulDiv(tokenAmount, 2 ** 192, ethAmount);

        vm.prank(address(lbp.auction()));
        vm.expectRevert(abi.encodeWithSelector(ISubscriber.InvalidTokenAmount.selector, tokenAmount + 1, tokenAmount));
        lbp.onNotify{value: ethAmount}(abi.encode(priceX192, tokenAmount + 1, ethAmount));
    }

    // ============ Fuzzed Tests ============

    /// @notice Tests onNotify with fuzzed inputs, expecting both success and revert cases
    /// @dev This test intentionally allows all valid uint128 inputs and checks if the resulting price
    ///      is within Uniswap V4's valid range. If valid, it expects success; if not, it expects
    ///      a revert with InvalidPrice error. This provides better coverage than constraining inputs.
    function test_fuzz_onNotify_withETH(uint128 tokenAmount, uint128 ethAmount) public {
        vm.assume(tokenAmount <= DEFAULT_TOTAL_SUPPLY / 2);

        // Prevent overflow in FullMath.mulDiv
        // We need to ensure that when calculating tokenAmount * 2^192,
        // the upper 256 bits (prod1) must be less than ethAmount
        // This happens when tokenAmount * 2^192 < ethAmount * 2^256
        // Which simplifies to: tokenAmount < ethAmount * 2^64
        if (ethAmount <= type(uint64).max) {
            // If ethAmount fits in uint64, we need tokenAmount < ethAmount * 2^64
            vm.assume(tokenAmount < ethAmount * (1 << 64));
        }

        // Setup
        sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

        // Calculate expected price
        uint256 priceX192 = FullMath.mulDiv(tokenAmount, 2 ** 192, ethAmount);
        uint160 expectedSqrtPrice = uint160(Math.sqrt(priceX192));

        // Check if the price is within valid bounds
        bool isValidPrice = expectedSqrtPrice >= TickMath.MIN_SQRT_PRICE && expectedSqrtPrice <= TickMath.MAX_SQRT_PRICE;

        vm.deal(address(lbp.auction()), ethAmount);
        vm.prank(address(lbp.auction()));

        if (isValidPrice) {
            // Should succeed
            lbp.onNotify{value: ethAmount}(abi.encode(priceX192, tokenAmount, ethAmount));

            // Verify
            assertEq(lbp.initialSqrtPriceX96(), expectedSqrtPrice);
            assertEq(lbp.initialTokenAmount(), tokenAmount);
            assertEq(lbp.initialCurrencyAmount(), ethAmount);
            assertEq(address(lbp).balance, ethAmount);
        } else {
            // Should revert with InvalidPrice
            vm.expectRevert(abi.encodeWithSelector(ISubscriber.InvalidPrice.selector, priceX192));
            lbp.onNotify{value: ethAmount}(abi.encode(priceX192, tokenAmount, ethAmount));
        }
    }

    function test_onNotify_withETH_revertsWithPriceTooLow() public {
        // This test verifies the fuzz test is correctly handling the revert case for prices below MIN_SQRT_PRICE
        uint128 tokenAmount = 1;
        uint128 ethAmount = type(uint128).max - 1; // This will create a price below MIN_SQRT_PRICE

        sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

        uint256 priceX192 = FullMath.mulDiv(tokenAmount, 2 ** 192, ethAmount);

        vm.deal(address(lbp.auction()), ethAmount);
        vm.prank(address(lbp.auction()));
        vm.expectRevert(abi.encodeWithSelector(ISubscriber.InvalidPrice.selector, priceX192));
        lbp.onNotify{value: ethAmount}(abi.encode(priceX192, tokenAmount, ethAmount));
    }

    // Note: Testing for prices above MAX_SQRT_PRICE is not feasible with uint128 inputs
    // The ratio tokenAmount/ethAmount would need to exceed ~3.4e38 to produce a sqrtPrice > MAX_SQRT_PRICE
    // This is impossible with uint128 values (max ~3.4e38) due to FullMath overflow protection
    // The fuzz test above properly handles all practically achievable price ranges

    // function test_fuzz_onNotify_withToken(uint128 tokenAmount, uint128 currencyAmount) public {
    //     vm.assume(tokenAmount > 0 && currencyAmount > 0);
    //     vm.assume(tokenAmount <= DEFAULT_TOTAL_SUPPLY / 2);
    //     vm.assume(currencyAmount <= type(uint128).max);

    //     // Ensure realistic price ratios to prevent overflow in FullMath.mulDiv
    //     // The failing case had currencyAmount/tokenAmount ≈ 6.25e28 which is too extreme
    //     // Let's limit to more realistic ratios

    //     // To prevent overflow in currencyAmount * 2^192, we need:
    //     // currencyAmount <= type(uint256).max / 2^192 ≈ 1.84e19
    //     // But we also want reasonable price ratios, so let's be more restrictive

    //     // Max price: 1 token = 1e12 currency units (trillion to 1)
    //     // Min price: 1 token = 1e-6 currency units (1 to million)
    //     if (tokenAmount >= 1e12) {
    //         vm.assume(currencyAmount <= tokenAmount * 1e12);
    //         vm.assume(currencyAmount >= tokenAmount / 1e6);
    //     } else {
    //         // For very small tokenAmounts, just ensure currencyAmount is reasonable
    //         vm.assume(currencyAmount <= 1e30); // Well below overflow threshold
    //     }

    //     // Setup with DAI
    //     setupWithCurrency(DAI);
    //     sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

    //     // Calculate expected price
    //     uint256 priceX192 = FullMath.mulDiv(currencyAmount, 2 ** 192, tokenAmount);
    //     uint160 expectedSqrtPrice = uint160(Math.sqrt(priceX192));

    //     // Set initial price
    //     deal(DAI, address(lbp.auction()), currencyAmount);
    //     vm.startPrank(address(lbp.auction()));
    //     ERC20(DAI).approve(address(lbp), currencyAmount);
    //     lbp.onNotify(priceX192, tokenAmount, currencyAmount);
    //     vm.stopPrank();

    //     // Verify
    //     assertEq(lbp.initialSqrtPriceX96(), expectedSqrtPrice);
    //     assertEq(lbp.initialTokenAmount(), tokenAmount);
    //     assertEq(lbp.initialCurrencyAmount(), currencyAmount);
    //     assertEq(ERC20(DAI).balanceOf(address(lbp)), currencyAmount);
    // }
}
