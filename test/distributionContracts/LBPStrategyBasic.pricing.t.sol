// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LBPStrategyBasicTestBase} from "./base/LBPStrategyBasicTestBase.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Math} from "@openzeppelin-latest/contracts/utils/math/Math.sol";
import {ERC20} from "@openzeppelin-latest/contracts/token/ERC20/ERC20.sol";
import {ILBPStrategyBasic} from "../../src/interfaces/ILBPStrategyBasic.sol";
import {IAuction} from "twap-auction/src/interfaces/IAuction.sol";
import {ICheckpointStorage} from "twap-auction/src/interfaces/ICheckpointStorage.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin-latest/contracts/token/ERC20/IERC20.sol";
import {InverseHelpers} from "../shared/InverseHelpers.sol";
import {TokenPricing} from "../../src/libraries/TokenPricing.sol";

// Mock auction contract that transfers ETH when sweepCurrency is called
contract MockAuctionWithSweep {
    uint256 immutable ethToTransfer;
    uint64 public endBlock;

    constructor(uint256 _ethToTransfer) {
        ethToTransfer = _ethToTransfer;
        endBlock = uint64(block.number - 1); // Set to past block so test passes the check
    }
}

// Mock auction contract that transfers ERC20 when sweepCurrency is called
contract MockAuctionWithERC20Sweep {
    address immutable tokenToTransfer;
    uint256 immutable amountToTransfer;
    uint64 public endBlock;

    constructor(address _token, uint256 _amount) {
        tokenToTransfer = _token;
        amountToTransfer = _amount;
        endBlock = uint64(block.number - 1); // Set to past block so test passes the check
    }
}

contract LBPStrategyBasicPricingTest is LBPStrategyBasicTestBase {
    uint256 constant Q96 = 2 ** 96;
    uint256 constant Q192 = 2 ** 192;

    event Validated(uint160 sqrtPriceX96, uint128 tokenAmount, uint128 currencyAmount);
    // ============ Helper Functions ============

    function sendCurrencyToLBP(address currency, uint256 amount) internal {
        if (currency == address(0)) {
            // Send ETH
            vm.deal(address(lbp), amount);
        } else {
            // Send ERC20
            deal(currency, address(lbp), amount);
        }
    }

    // ============ ETH Currency Tests ============

    function test_validate_withETH_succeeds() public {
        // Setup: Send tokens to LBP and create auction
        sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

        uint128 ethAmount = DEFAULT_TOTAL_SUPPLY / 2;

        // Mock auction functions
        uint256 pricePerToken = 1 << 96;
        mockAuctionClearingPrice(lbp, pricePerToken);
        mockAuctionEndBlock(lbp, uint64(block.number - 1)); // Mock past block so auction is ended

        // Deploy and etch mock auction that will handle sweepCurrency
        MockAuctionWithSweep mockAuction = new MockAuctionWithSweep(ethAmount);
        vm.deal(address(lbp.auction()), ethAmount);
        vm.etch(address(lbp.auction()), address(mockAuction).code);

        // Mock the clearingPrice again after etching (since we replaced the code)
        mockAuctionClearingPrice(lbp, pricePerToken);

        mockCurrencyRaised(lbp, ethAmount);

        // mock the auction giving ETH to the LBP
        vm.deal(address(lbp), ethAmount);

        // Calculate expected values
        // inverse price because currency is ETH
        pricePerToken = InverseHelpers.invertPrice(pricePerToken);
        uint256 priceX192 = pricePerToken << 96;
        uint160 expectedSqrtPrice = uint160(Math.sqrt(priceX192));
        uint128 expectedTokenAmount = uint128(FullMath.mulDiv(priceX192, ethAmount, Q192));

        vm.expectEmit(true, true, true, true);
        emit Validated(expectedSqrtPrice, expectedTokenAmount, ethAmount);

        // Call validate
        vm.prank(address(lbp.auction()));
        lbp.validate();

        // Verify state
        assertEq(lbp.initialSqrtPriceX96(), expectedSqrtPrice);
        assertEq(lbp.initialTokenAmount(), expectedTokenAmount);
        assertEq(lbp.initialCurrencyAmount(), ethAmount);
        assertEq(address(lbp).balance, ethAmount); // LBP should have received ETH
    }

    function test_validate_revertsWithInvalidPrice_tooLow() public {
        // Setup with DAI as currency1
        setupWithCurrency(DAI);

        // Setup: Send tokens to LBP and create auction
        sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

        uint128 daiAmount = DEFAULT_TOTAL_SUPPLY / 2;

        // Mock a very low price that will result in sqrtPrice below MIN_SQRT_PRICE
        uint256 veryLowPrice = uint256(TickMath.MIN_SQRT_PRICE - 1) * (uint256(TickMath.MIN_SQRT_PRICE) - 1); // Extremely low price
        veryLowPrice = veryLowPrice >> 96;
        mockAuctionClearingPrice(lbp, veryLowPrice);
        mockAuctionEndBlock(lbp, uint64(block.number - 1)); // Mock past block so auction is ended

        // Deploy and etch mock auction that will handle ERC20 sweepCurrency
        MockAuctionWithERC20Sweep mockAuction = new MockAuctionWithERC20Sweep(DAI, daiAmount);
        vm.etch(address(lbp.auction()), address(mockAuction).code);

        // After etching, we need to deal DAI to the auction since vm.etch doesn't preserve balances
        deal(DAI, address(lbp.auction()), daiAmount);

        // Mock the clearingPrice again after etching
        mockAuctionClearingPrice(lbp, veryLowPrice);

        mockCurrencyRaised(lbp, daiAmount);

        deal(DAI, address(lbp), daiAmount);

        // Expect revert with InvalidPrice
        vm.prank(address(lbp.auction()));
        vm.expectRevert(abi.encodeWithSelector(TokenPricing.InvalidPrice.selector, veryLowPrice));
        lbp.validate();
    }

    // ============ Non-ETH Currency Tests ============

    function test_validate_withNonETHCurrency_succeeds() public {
        // Setup with DAI as currency1
        setupWithCurrency(DAI);

        // Send tokens to LBP
        sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

        uint128 daiAmount = DEFAULT_TOTAL_SUPPLY / 2;

        // Mock auction functions
        uint256 pricePerToken = 20 << 96;
        mockAuctionClearingPrice(lbp, pricePerToken);
        mockAuctionEndBlock(lbp, uint64(block.number - 1)); // Mock past block so auction is ended

        // Deploy and etch mock auction that will handle ERC20 sweepCurrency
        MockAuctionWithERC20Sweep mockAuction = new MockAuctionWithERC20Sweep(DAI, daiAmount);
        vm.etch(address(lbp.auction()), address(mockAuction).code);

        // After etching, we need to deal DAI to the auction since vm.etch doesn't preserve balances
        deal(DAI, address(lbp.auction()), daiAmount);

        // Mock the clearingPrice again after etching
        mockAuctionClearingPrice(lbp, pricePerToken);

        mockCurrencyRaised(lbp, daiAmount);

        deal(DAI, address(lbp), daiAmount);

        // Calculate expected values
        uint256 priceX192 = pricePerToken << 96;
        uint160 expectedSqrtPrice = uint160(Math.sqrt(priceX192));
        uint128 expectedTokenAmount = uint128(FullMath.mulDiv(daiAmount, Q192, priceX192));

        vm.expectEmit(true, true, true, true);
        emit Validated(expectedSqrtPrice, expectedTokenAmount, daiAmount);

        // Call validate
        vm.prank(address(lbp.auction()));
        lbp.validate();

        // Verify state
        assertEq(lbp.initialSqrtPriceX96(), expectedSqrtPrice);
        assertEq(lbp.initialTokenAmount(), expectedTokenAmount);
        assertEq(lbp.initialCurrencyAmount(), daiAmount);

        // Verify balances
        assertEq(ERC20(DAI).balanceOf(address(lbp)), daiAmount);
    }

    // ============ Price Calculation Tests ============

    function test_priceCalculations() public pure {
        // Test 1:1 price
        uint256 priceX192 = FullMath.mulDiv(1e18, Q192, 1e18);
        uint160 sqrtPriceX96 = uint160(Math.sqrt(priceX192));
        assertEq(sqrtPriceX96, 79228162514264337593543950336);

        // Test 100:1 price
        priceX192 = FullMath.mulDiv(100e18, Q192, 1e18);
        sqrtPriceX96 = uint160(Math.sqrt(priceX192));
        assertEq(sqrtPriceX96, 792281625142643375935439503360);

        // Test 1:100 price
        priceX192 = FullMath.mulDiv(1e18, Q192, 100e18);
        sqrtPriceX96 = uint160(Math.sqrt(priceX192));
        assertEq(sqrtPriceX96, 7922816251426433759354395033);

        // Test arbitrary price (111:333)
        priceX192 = FullMath.mulDiv(111e18, Q192, 333e18);
        sqrtPriceX96 = uint160(Math.sqrt(priceX192));
        assertEq(sqrtPriceX96, 45742400955009932534161870629);

        // Test inverse (333:111)
        priceX192 = FullMath.mulDiv(333e18, Q192, 111e18);
        sqrtPriceX96 = uint160(Math.sqrt(priceX192));
        assertEq(sqrtPriceX96, 137227202865029797602485611888);
    }

    // ============ Fuzzed Tests ============

    /// @notice Tests validate with fuzzed inputs
    /// @dev This test checks various price and currency amount combinations
    function test_fuzz_validate_withETH(uint256 pricePerToken, uint128 ethAmount, uint24 tokenSplit) public {
        vm.assume(pricePerToken <= type(uint160).max);
        tokenSplit = uint24(bound(tokenSplit, 1, 1e7));

        migratorParams = createMigratorParams(address(0), 500, 20, uint24(tokenSplit), address(3));
        _deployLBPStrategy(DEFAULT_TOTAL_SUPPLY);

        // Setup
        sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

        // Mock auction functions
        mockAuctionClearingPrice(lbp, pricePerToken);
        mockAuctionEndBlock(lbp, uint64(block.number - 1));

        // Deploy and etch mock auction
        MockAuctionWithSweep mockAuction = new MockAuctionWithSweep(ethAmount);
        vm.deal(address(lbp.auction()), ethAmount);
        vm.etch(address(lbp.auction()), address(mockAuction).code);

        // Mock the clearingPrice again after etching
        mockAuctionClearingPrice(lbp, pricePerToken);

        mockCurrencyRaised(lbp, ethAmount);

        deal(address(lbp), ethAmount);

        if (pricePerToken != 0) {
            pricePerToken = InverseHelpers.invertPrice(pricePerToken);
        }

        // Calculate expected values
        uint256 priceX192 = pricePerToken << 96;
        uint160 expectedSqrtPrice = uint160(Math.sqrt(priceX192));
        uint256 expectedTokenAmount = FullMath.mulDiv(priceX192, ethAmount, Q192);

        // Check if the price is within valid bounds
        bool isValidPrice = expectedSqrtPrice >= TickMath.MIN_SQRT_PRICE && expectedSqrtPrice <= TickMath.MAX_SQRT_PRICE;
        bool priceFitsInUint160 = pricePerToken <= type(uint160).max;
        bool isLeftoverToken = expectedTokenAmount <= lbp.reserveSupply();

        // case 1. price is 0
        // case 2. price is > type(uint160).max
        // case 3. sqrt price is not in valid range
        // case 4. token amt > reserve supply
        // case 5. corresponding currency amt > type(uint128).max

        if (!isValidPrice || !priceFitsInUint160) {
            // Should revert with InvalidPrice
            vm.prank(address(lbp.auction()));
            vm.expectRevert(abi.encodeWithSelector(TokenPricing.InvalidPrice.selector, pricePerToken));
            lbp.validate();
        } else if (!isLeftoverToken) {
            if (FullMath.mulDiv(lbp.reserveSupply(), Q192, priceX192) > type(uint128).max) {
                // Should revert with AmountOverflow
                vm.prank(address(lbp.auction()));
                vm.expectRevert(abi.encodeWithSelector(TokenPricing.AmountOverflow.selector, expectedTokenAmount));
                lbp.validate();
            }
        }
    }

    function test_validate_withETH_revertsWithPriceTooHigh() public {
        // This test verifies the handling of prices above MAX_SQRT_PRICE
        sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

        // For ETH, price is inverted, so we need a very LOW clearing price to get a HIGH actual price
        // To get sqrtPrice > MAX_SQRT_PRICE, we need a price that when inverted is very high
        // clearingPrice = (1 << 96)^2 / actualPrice
        // We want actualPrice that results in sqrtPrice > MAX_SQRT_PRICE
        // MAX_SQRT_PRICE is approximately 1461446703485210103287273052203988822378723970342
        // So we need a clearing price close to 0 but not 0
        uint256 veryLowClearingPrice = 1; // Minimal non-zero price
        mockAuctionClearingPrice(lbp, veryLowClearingPrice);
        mockAuctionEndBlock(lbp, uint64(block.number - 1));

        // Set up mock auction
        uint128 ethAmount = 1e18;
        MockAuctionWithSweep mockAuction = new MockAuctionWithSweep(ethAmount);
        vm.deal(address(lbp.auction()), ethAmount);
        vm.etch(address(lbp.auction()), address(mockAuction).code);

        // Mock the clearingPrice again after etching
        mockAuctionClearingPrice(lbp, veryLowClearingPrice);

        mockCurrencyRaised(lbp, ethAmount);

        deal(address(lbp), ethAmount);

        // Calculate the inverted price that will be used in the contract
        uint256 invertedPrice = InverseHelpers.invertPrice(veryLowClearingPrice);

        vm.prank(address(lbp.auction()));
        // Expect revert with InvalidPrice (the error will contain the inverted price)
        vm.expectRevert(abi.encodeWithSelector(TokenPricing.InvalidPrice.selector, invertedPrice));
        lbp.validate();
    }

    function test_fuzz_validate_withToken(uint256 pricePerToken, uint128 currencyAmount, uint16 tokenSplit) public {
        vm.assume(pricePerToken <= type(uint160).max);
        tokenSplit = uint16(bound(tokenSplit, 1, 10_000));

        migratorParams = createMigratorParams(
            DAI,
            500,
            20,
            uint16(tokenSplit),
            address(3),
            uint64(block.number + 500),
            uint64(block.number + 1_000),
            address(this),
            true
        );
        _deployLBPStrategy(DEFAULT_TOTAL_SUPPLY);

        // Setup with DAI
        setupWithCurrency(DAI);
        sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

        // Mock auction functions
        mockAuctionClearingPrice(lbp, pricePerToken);
        mockAuctionEndBlock(lbp, uint64(block.number - 1));

        // Deploy and etch mock auction for ERC20
        MockAuctionWithERC20Sweep mockAuction = new MockAuctionWithERC20Sweep(DAI, currencyAmount);
        vm.etch(address(lbp.auction()), address(mockAuction).code);

        // After etching, we need to deal DAI to the auction since vm.etch doesn't preserve balances
        deal(DAI, address(lbp.auction()), currencyAmount);

        // Mock the clearingPrice again after etching
        mockAuctionClearingPrice(lbp, pricePerToken);

        mockCurrencyRaised(lbp, currencyAmount);
        deal(DAI, address(lbp), currencyAmount);

        // Calculate expected values
        // Only invert price if currency < token (matching the implementation)
        uint256 priceX192 = pricePerToken << 96;
        uint160 expectedSqrtPrice = uint160(Math.sqrt(priceX192));

        bool isValidPrice;
        uint256 tokenAmountUint256;
        if (pricePerToken != 0) {
            tokenAmountUint256 = uint128(FullMath.mulDiv(currencyAmount, Q192, priceX192));
        } else {
            isValidPrice = false;
        }

        bool tokenAmountFitsInUint128 = tokenAmountUint256 <= type(uint128).max;

        // Check if the price is within valid bounds
        isValidPrice = expectedSqrtPrice >= TickMath.MIN_SQRT_PRICE && expectedSqrtPrice <= TickMath.MAX_SQRT_PRICE;

        if (!isValidPrice) {
            // Should revert with InvalidPrice
            vm.prank(address(lbp.auction()));
            vm.expectRevert(abi.encodeWithSelector(TokenPricing.InvalidPrice.selector, pricePerToken));
            lbp.validate();
        } else if (!tokenAmountFitsInUint128) {
            // Should revert with InvalidTokenAmount
            vm.prank(address(lbp.auction()));
            vm.expectRevert();
            lbp.validate();
        } else {
            // Token amount fits in uint128, so we can safely cast
            uint128 expectedTokenAmount = uint128(tokenAmountUint256);
            bool isValidTokenAmount = expectedTokenAmount <= lbp.reserveSupply();

            if (isValidTokenAmount) {
                // Should succeed
                vm.prank(address(lbp.auction()));
                lbp.validate();

                // Verify
                assertEq(lbp.initialSqrtPriceX96(), expectedSqrtPrice);
                assertEq(lbp.initialTokenAmount(), expectedTokenAmount);
                assertEq(lbp.initialCurrencyAmount(), currencyAmount);
                assertEq(ERC20(DAI).balanceOf(address(lbp)), currencyAmount);
            } else {
                // Should revert with InvalidTokenAmount
                vm.startPrank(address(lbp.auction()));
                lbp.validate();
                assertEq(lbp.initialTokenAmount(), lbp.reserveSupply());
                assertGt(lbp.leftoverCurrency(), 0);
            }
        }
    }
}
