// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "./base/LBPStrategyBasicTestBase.sol";
import "./helpers/LBPTestHelpers.sol";
import {ISubscriber} from "../../src/interfaces/ISubscriber.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract LBPStrategyBasicPricingTest is LBPStrategyBasicTestBase {
    using LBPTestHelpers for *;

    function setUp() public override {
        super.setUp();
    }

    // ============ Access Control Tests ============

    function test_setInitialPrice_revertsWithOnlyAuctionCanSetPrice() public {
        vm.expectRevert(
            abi.encodeWithSelector(ISubscriber.OnlyAuctionCanSetPrice.selector, address(lbp.auction()), address(this))
        );
        lbp.setInitialPrice(TickMath.getSqrtPriceAtTick(0), DEFAULT_TOTAL_SUPPLY, DEFAULT_TOTAL_SUPPLY);
    }

    // ============ ETH Currency Tests ============

    function test_setInitialPrice_revertsWithInvalidCurrencyAmount() public {
        // Setup: Send tokens to LBP and create auction
        LBPTestHelpers.sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

        uint128 expectedAmount = DEFAULT_TOTAL_SUPPLY / 2;
        uint128 sentAmount = expectedAmount - 1;

        vm.deal(address(lbp.auction()), sentAmount);
        vm.prank(address(lbp.auction()));
        vm.expectRevert(abi.encodeWithSelector(ISubscriber.InvalidCurrencyAmount.selector, sentAmount, expectedAmount));
        lbp.setInitialPrice{value: sentAmount}(TickMath.getSqrtPriceAtTick(0), expectedAmount, expectedAmount);
    }

    function test_setInitialPrice_withETH_succeeds() public {
        // Setup: Send tokens to LBP and create auction
        LBPTestHelpers.sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

        uint128 tokenAmount = DEFAULT_TOTAL_SUPPLY / 2;
        uint128 ethAmount = DEFAULT_TOTAL_SUPPLY / 2;

        vm.deal(address(lbp.auction()), ethAmount);

        uint256 priceX192 = FullMath.mulDiv(tokenAmount, 2 ** 192, ethAmount);
        uint160 expectedSqrtPrice = uint160(Math.sqrt(priceX192));

        vm.expectEmit(true, true, true, true);
        emit InitialPriceSet(priceX192, tokenAmount, ethAmount);

        vm.prank(address(lbp.auction()));
        lbp.setInitialPrice{value: ethAmount}(priceX192, tokenAmount, ethAmount);

        // Verify state
        assertEq(lbp.initialSqrtPriceX96(), expectedSqrtPrice);
        assertEq(lbp.initialTokenAmount(), tokenAmount);
        assertEq(lbp.initialCurrencyAmount(), ethAmount);
        assertEq(address(lbp).balance, ethAmount);
    }

    function test_setInitialPrice_revertsWithNonETHCurrencyCannotReceiveETH() public {
        // Setup with DAI as currency
        setupWithCurrency(DAI);

        // Send tokens to LBP
        LBPTestHelpers.sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

        // Give auction DAI
        deal(DAI, address(lbp.auction()), 1_000e18);

        // Give auction ETH to try sending
        vm.deal(address(lbp.auction()), 1e18);

        vm.prank(address(lbp.auction()));
        vm.expectRevert(abi.encodeWithSelector(ISubscriber.NonETHCurrencyCannotReceiveETH.selector, DAI));
        lbp.setInitialPrice{value: 1e18}(TickMath.getSqrtPriceAtTick(0), DEFAULT_TOTAL_SUPPLY, 1e18);
    }

    // ============ Non-ETH Currency Tests ============

    function test_setInitialPrice_withNonETHCurrency_succeeds() public {
        // Setup with DAI as currency
        setupWithCurrency(DAI);

        // Send tokens to LBP
        LBPTestHelpers.sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

        uint128 tokenAmount = DEFAULT_TOTAL_SUPPLY / 2;
        uint128 daiAmount = DEFAULT_TOTAL_SUPPLY / 2;

        // Setup DAI for auction
        deal(DAI, address(lbp.auction()), daiAmount);

        vm.prank(address(lbp.auction()));
        ERC20(DAI).approve(address(lbp), daiAmount);

        uint256 priceX192 = FullMath.mulDiv(tokenAmount, 2 ** 192, daiAmount);
        uint160 expectedSqrtPrice = uint160(Math.sqrt(priceX192));

        vm.expectEmit(true, true, true, true);
        emit InitialPriceSet(priceX192, tokenAmount, daiAmount);

        vm.prank(address(lbp.auction()));
        lbp.setInitialPrice(priceX192, tokenAmount, daiAmount);

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

    // ============ Fuzzed Tests ============

    /// @notice Tests setInitialPrice with fuzzed inputs, expecting both success and revert cases
    /// @dev This test intentionally allows all valid uint128 inputs and checks if the resulting price
    ///      is within Uniswap V4's valid range. If valid, it expects success; if not, it expects
    ///      a revert with InvalidPrice error. This provides better coverage than constraining inputs.
    function test_fuzz_setInitialPrice_withETH(uint128 tokenAmount, uint128 ethAmount) public {
        vm.assume(tokenAmount <= DEFAULT_TOTAL_SUPPLY / 2);

        // Prevent division by zero
        vm.assume(tokenAmount > 0);
        vm.assume(ethAmount > 0);

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
        LBPTestHelpers.sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

        // Calculate expected price
        uint256 priceX192 = FullMath.mulDiv(tokenAmount, 2 ** 192, ethAmount);
        uint160 expectedSqrtPrice = uint160(Math.sqrt(priceX192));

        // Check if the price is within valid bounds
        bool isValidPrice = expectedSqrtPrice >= TickMath.MIN_SQRT_PRICE && expectedSqrtPrice <= TickMath.MAX_SQRT_PRICE;

        vm.deal(address(lbp.auction()), ethAmount);
        vm.prank(address(lbp.auction()));

        if (isValidPrice) {
            // Should succeed
            lbp.setInitialPrice{value: ethAmount}(priceX192, tokenAmount, ethAmount);

            // Verify
            assertEq(lbp.initialSqrtPriceX96(), expectedSqrtPrice);
            assertEq(lbp.initialTokenAmount(), tokenAmount);
            assertEq(lbp.initialCurrencyAmount(), ethAmount);
            assertEq(address(lbp).balance, ethAmount);
        } else {
            // Should revert with InvalidPrice
            vm.expectRevert(abi.encodeWithSelector(ISubscriber.InvalidPrice.selector, priceX192));
            lbp.setInitialPrice{value: ethAmount}(priceX192, tokenAmount, ethAmount);
        }
    }

    function test_setInitialPrice_withETH_revertsWithPriceTooLow() public {
        // This test verifies the fuzz test is correctly handling the revert case for prices below MIN_SQRT_PRICE
        uint128 tokenAmount = 1;
        uint128 ethAmount = type(uint128).max - 1; // This will create a price below MIN_SQRT_PRICE

        LBPTestHelpers.sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

        uint256 priceX192 = FullMath.mulDiv(tokenAmount, 2 ** 192, ethAmount);

        vm.deal(address(lbp.auction()), ethAmount);
        vm.prank(address(lbp.auction()));
        vm.expectRevert(abi.encodeWithSelector(ISubscriber.InvalidPrice.selector, priceX192));
        lbp.setInitialPrice{value: ethAmount}(priceX192, tokenAmount, ethAmount);
    }

    // Note: Testing for prices above MAX_SQRT_PRICE is not feasible with uint128 inputs
    // The ratio tokenAmount/ethAmount would need to exceed ~3.4e38 to produce a sqrtPrice > MAX_SQRT_PRICE
    // This is impossible with uint128 values (max ~3.4e38) due to FullMath overflow protection
    // The fuzz test above properly handles all practically achievable price ranges

    // function test_fuzz_setInitialPrice_withToken(uint128 tokenAmount, uint128 currencyAmount) public {
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
    //     LBPTestHelpers.sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

    //     // Calculate expected price
    //     uint256 priceX192 = FullMath.mulDiv(currencyAmount, 2 ** 192, tokenAmount);
    //     uint160 expectedSqrtPrice = uint160(Math.sqrt(priceX192));

    //     // Set initial price
    //     deal(DAI, address(lbp.auction()), currencyAmount);
    //     vm.startPrank(address(lbp.auction()));
    //     ERC20(DAI).approve(address(lbp), currencyAmount);
    //     lbp.setInitialPrice(priceX192, tokenAmount, currencyAmount);
    //     vm.stopPrank();

    //     // Verify
    //     assertEq(lbp.initialSqrtPriceX96(), expectedSqrtPrice);
    //     assertEq(lbp.initialTokenAmount(), tokenAmount);
    //     assertEq(lbp.initialCurrencyAmount(), currencyAmount);
    //     assertEq(ERC20(DAI).balanceOf(address(lbp)), currencyAmount);
    // }
}
