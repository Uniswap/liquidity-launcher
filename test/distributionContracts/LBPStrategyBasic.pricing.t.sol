// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LBPStrategyBasicTestBase} from "./base/LBPStrategyBasicTestBase.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {ILBPStrategyBasic} from "../../src/interfaces/ILBPStrategyBasic.sol";
import {IAuction} from "twap-auction/src/interfaces/IAuction.sol";
import {ICheckpointStorage} from "twap-auction/src/interfaces/ICheckpointStorage.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

// Mock auction contract that transfers ETH when sweepCurrency is called
contract MockAuctionWithSweep {
    uint256 immutable ethToTransfer;
    uint64 public endBlock;

    constructor(uint256 _ethToTransfer) {
        ethToTransfer = _ethToTransfer;
        endBlock = uint64(block.number - 1); // Set to past block so test passes the check
    }

    function sweepCurrency() external {
        // Transfer ETH to the caller (LBP contract)
        (bool success,) = msg.sender.call{value: ethToTransfer}("");
        require(success, "ETH transfer failed");
    }

    function clearingPrice() external pure returns (uint256) {
        return 1e18; // Default price, will be overridden by mock
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

    function sweepCurrency() external {
        // Transfer ERC20 to the caller (LBP contract)
        IERC20(tokenToTransfer).transfer(msg.sender, amountToTransfer);
    }

    function clearingPrice() external pure returns (uint256) {
        return 1e18; // Default price, will be overridden by mock
    }
}

contract LBPStrategyBasicPricingTest is LBPStrategyBasicTestBase {
    uint256 constant Q96 = 2 ** 96;
    // ============ Helper Functions ============

    function mockClearingPrice(uint256 price) internal {
        // Mock the auction's clearingPrice function
        vm.mockCall(
            address(lbp.auction()), abi.encodeWithSelector(ICheckpointStorage.clearingPrice.selector), abi.encode(price)
        );
    }

    function mockSweepCurrency() internal {
        // Mock the auction's sweepCurrency function to simulate fund transfer
        vm.mockCallRevert(address(lbp.auction()), abi.encodeWithSignature("sweepCurrency()"), "");
    }

    function mockEndBlock(uint64 blockNumber) internal {
        // Mock the auction's endBlock function
        vm.mockCall(address(lbp.auction()), abi.encodeWithSignature("endBlock()"), abi.encode(blockNumber));
    }

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

    function test_fetchPriceAndCurrencyFromAuction_withETH_succeeds() public {
        // Setup: Send tokens to LBP and create auction
        sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

        uint128 ethAmount = DEFAULT_TOTAL_SUPPLY / 2;

        // Mock auction functions
        uint256 pricePerToken = 13483e18;
        mockClearingPrice(pricePerToken);
        mockEndBlock(uint64(block.number - 1)); // Mock past block so auction is ended

        // Deploy and etch mock auction that will handle sweepCurrency
        MockAuctionWithSweep mockAuction = new MockAuctionWithSweep(ethAmount);
        vm.deal(address(lbp.auction()), ethAmount);
        vm.etch(address(lbp.auction()), address(mockAuction).code);

        // Mock the clearingPrice again after etching (since we replaced the code)
        mockClearingPrice(pricePerToken);

        // Call fetchPriceAndCurrencyFromAuction
        lbp.fetchPriceAndCurrencyFromAuction();

        // Calculate expected values
        uint256 priceX192 = pricePerToken << 96;
        uint160 expectedSqrtPrice = uint160(Math.sqrt(priceX192));
        uint128 expectedTokenAmount = uint128(FullMath.mulDiv(priceX192, ethAmount, lbp.Q192()));

        // Verify state
        assertEq(lbp.initialSqrtPriceX96(), expectedSqrtPrice);
        assertEq(lbp.initialTokenAmount(), expectedTokenAmount);
        assertEq(lbp.initialCurrencyAmount(), ethAmount);
        assertEq(address(lbp).balance, ethAmount); // LBP should have received ETH
    }

    function test_fetchPriceAndCurrencyFromAuction_revertsWithInvalidPrice_tooLow() public {
        // Setup: Send tokens to LBP and create auction
        sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

        // Mock a very low price that will result in sqrtPrice below MIN_SQRT_PRICE
        uint256 veryLowPrice = uint256(TickMath.MIN_SQRT_PRICE - 1) * (uint256(TickMath.MIN_SQRT_PRICE) - 1); // Extremely low price
        veryLowPrice = veryLowPrice >> 96;
        mockClearingPrice(veryLowPrice);
        mockEndBlock(uint64(block.number - 1)); // Mock past block so auction is ended

        // Set up mock auction with ETH
        uint128 ethAmount = 1e18;
        MockAuctionWithSweep mockAuction = new MockAuctionWithSweep(ethAmount);
        vm.deal(address(lbp.auction()), ethAmount);
        vm.etch(address(lbp.auction()), address(mockAuction).code);

        // Mock the clearingPrice again after etching
        mockClearingPrice(veryLowPrice);

        // Expect revert with InvalidPrice
        vm.expectRevert(abi.encodeWithSelector(ILBPStrategyBasic.InvalidPrice.selector, veryLowPrice));
        lbp.fetchPriceAndCurrencyFromAuction();
    }

    // TODO
    // function test_fetchPriceAndCurrencyFromAuction_revertsWithInvalidTokenAmount() public {
    //     // Setup: Send tokens to LBP and create auction
    //     sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

    //     uint128 reserveSupply = lbp.reserveSupply();

    //     // Mock a price that will result in tokenAmount > reserveSupply
    //     // High price means more tokens needed for the given currency
    //     uint256 highPrice = 10e18; // 10 ETH per token
    //     mockClearingPrice(highPrice);
    //     mockEndBlock(uint64(block.number - 1)); // Mock past block so auction is ended

    //     // Send a large amount of ETH that would require more tokens than available
    //     uint256 largeEthAmount = uint256(reserveSupply) * 11e18 / 10e18; // Would need 110% of reserve

    //     // Set up mock auction with large ETH amount
    //     MockAuctionWithSweep mockAuction = new MockAuctionWithSweep(largeEthAmount);
    //     vm.deal(address(lbp.auction()), largeEthAmount);
    //     vm.etch(address(lbp.auction()), address(mockAuction).code);

    //     // Mock the clearingPrice again after etching
    //     mockClearingPrice(highPrice);

    //     // Calculate what the token amount would be
    //     uint256 priceX192 = highPrice << 96;
    //     uint128 invalidTokenAmount = uint128(FullMath.mulDiv(priceX192, largeEthAmount, lbp.Q192()));

    //     // Expect revert with InvalidTokenAmount
    //     vm.expectRevert(
    //         abi.encodeWithSelector(ILBPStrategyBasic.InvalidTokenAmount.selector, invalidTokenAmount, reserveSupply)
    //     );
    //     lbp.fetchPriceAndCurrencyFromAuction();
    // }

    // ============ Non-ETH Currency Tests ============

    function test_fetchPriceAndCurrencyFromAuction_withNonETHCurrency_succeeds() public {
        // Setup with DAI as currency
        setupWithCurrency(DAI);

        // Send tokens to LBP
        sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

        uint128 daiAmount = DEFAULT_TOTAL_SUPPLY / 2;

        // Mock auction functions
        uint256 pricePerToken = 13533e18;
        mockClearingPrice(pricePerToken);
        mockEndBlock(uint64(block.number - 1)); // Mock past block so auction is ended

        // Deploy and etch mock auction that will handle ERC20 sweepCurrency
        MockAuctionWithERC20Sweep mockAuction = new MockAuctionWithERC20Sweep(DAI, daiAmount);
        vm.etch(address(lbp.auction()), address(mockAuction).code);

        // After etching, we need to deal DAI to the auction since vm.etch doesn't preserve balances
        deal(DAI, address(lbp.auction()), daiAmount);

        // Mock the clearingPrice again after etching
        mockClearingPrice(pricePerToken);

        // Call fetchPriceAndCurrencyFromAuction
        lbp.fetchPriceAndCurrencyFromAuction();

        // Calculate expected values
        uint256 priceX192 = pricePerToken << 96;
        uint160 expectedSqrtPrice = uint160(Math.sqrt(priceX192));
        uint128 expectedTokenAmount = uint128(FullMath.mulDiv(priceX192, daiAmount, lbp.Q192()));

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

    /// @notice Tests fetchPriceAndCurrencyFromAuction with fuzzed inputs
    /// @dev This test checks various price and currency amount combinations
    function test_fuzz_fetchPriceAndCurrencyFromAuction_withETH(uint256 pricePerToken, uint128 ethAmount) public {
        vm.assume(pricePerToken > 0 && pricePerToken <= 100e18); // Reasonable price range: 0 to 100 ETH per token
        vm.assume(ethAmount > 0 && ethAmount <= 1_000e18); // Reasonable ETH amount

        // Setup
        sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

        // Mock auction functions
        mockClearingPrice(pricePerToken);
        mockEndBlock(uint64(block.number - 1));

        // Deploy and etch mock auction
        MockAuctionWithSweep mockAuction = new MockAuctionWithSweep(ethAmount);
        vm.deal(address(lbp.auction()), ethAmount);
        vm.etch(address(lbp.auction()), address(mockAuction).code);

        // Mock the clearingPrice again after etching
        mockClearingPrice(pricePerToken);

        // Calculate expected values
        uint256 priceX192 = pricePerToken << 96;
        uint160 expectedSqrtPrice = uint160(Math.sqrt(priceX192));
        uint128 expectedTokenAmount = uint128(FullMath.mulDiv(priceX192, ethAmount, lbp.Q192()));

        // Check if the price is within valid bounds
        bool isValidPrice = expectedSqrtPrice >= TickMath.MIN_SQRT_PRICE && expectedSqrtPrice <= TickMath.MAX_SQRT_PRICE;
        bool isValidTokenAmount = expectedTokenAmount <= lbp.reserveSupply();

        if (isValidPrice && isValidTokenAmount) {
            // Should succeed
            lbp.fetchPriceAndCurrencyFromAuction();

            // Verify
            assertEq(lbp.initialSqrtPriceX96(), expectedSqrtPrice);
            assertEq(lbp.initialTokenAmount(), expectedTokenAmount);
            assertEq(lbp.initialCurrencyAmount(), ethAmount);
            assertEq(address(lbp).balance, ethAmount);
        } else if (!isValidPrice) {
            // Should revert with InvalidPrice
            vm.expectRevert(abi.encodeWithSelector(ILBPStrategyBasic.InvalidPrice.selector, priceX192));
            lbp.fetchPriceAndCurrencyFromAuction();
        } else {
            // Should revert with InvalidTokenAmount
            vm.expectRevert(
                abi.encodeWithSelector(
                    ILBPStrategyBasic.InvalidTokenAmount.selector, expectedTokenAmount, lbp.reserveSupply()
                )
            );
            lbp.fetchPriceAndCurrencyFromAuction();
        }
    }

    // TODO
    // function test_fetchPriceAndCurrencyFromAuction_withETH_revertsWithPriceTooHigh() public {
    //     // This test verifies the handling of prices above MAX_SQRT_PRICE
    //     sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

    //     // Mock an extremely high price
    //     uint256 veryHighPrice = uint256(TickMath.MAX_SQRT_PRICE + 1) * (uint256(TickMath.MAX_SQRT_PRICE) + 1); // Extremely high price
    //     veryHighPrice = veryHighPrice >> 96;
    //     mockClearingPrice(veryHighPrice);
    //     mockEndBlock(uint64(block.number - 1));

    //     // Set up mock auction
    //     uint128 ethAmount = 1e18;
    //     MockAuctionWithSweep mockAuction = new MockAuctionWithSweep(ethAmount);
    //     vm.deal(address(lbp.auction()), ethAmount);
    //     vm.etch(address(lbp.auction()), address(mockAuction).code);

    //     // Mock the clearingPrice again after etching
    //     mockClearingPrice(veryHighPrice);

    //     // Expect revert with InvalidPrice
    //     vm.expectRevert(abi.encodeWithSelector(ILBPStrategyBasic.InvalidPrice.selector, veryHighPrice));
    //     lbp.fetchPriceAndCurrencyFromAuction();
    // }

    function test_fuzz_fetchPriceAndCurrencyFromAuction_withToken(uint256 pricePerToken, uint128 currencyAmount)
        public
    {
        vm.assume(pricePerToken > 0 && pricePerToken <= 100e18); // Reasonable price range
        vm.assume(currencyAmount > 0 && currencyAmount <= 1_000e18); // Reasonable currency amount

        // Setup with DAI
        setupWithCurrency(DAI);
        sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

        // Mock auction functions
        mockClearingPrice(pricePerToken);
        mockEndBlock(uint64(block.number - 1));

        // Deploy and etch mock auction for ERC20
        MockAuctionWithERC20Sweep mockAuction = new MockAuctionWithERC20Sweep(DAI, currencyAmount);
        vm.etch(address(lbp.auction()), address(mockAuction).code);

        // After etching, we need to deal DAI to the auction since vm.etch doesn't preserve balances
        deal(DAI, address(lbp.auction()), currencyAmount);

        // Mock the clearingPrice again after etching
        mockClearingPrice(pricePerToken);

        // Calculate expected values
        uint256 priceX192 = pricePerToken << 96;
        uint160 expectedSqrtPrice = uint160(Math.sqrt(priceX192));
        uint128 expectedTokenAmount = uint128(FullMath.mulDiv(priceX192, currencyAmount, lbp.Q192()));

        // Check if the price is within valid bounds
        bool isValidPrice = expectedSqrtPrice >= TickMath.MIN_SQRT_PRICE && expectedSqrtPrice <= TickMath.MAX_SQRT_PRICE;
        bool isValidTokenAmount = expectedTokenAmount <= lbp.reserveSupply();

        if (isValidPrice && isValidTokenAmount) {
            // Should succeed
            lbp.fetchPriceAndCurrencyFromAuction();

            // Verify
            assertEq(lbp.initialSqrtPriceX96(), expectedSqrtPrice);
            assertEq(lbp.initialTokenAmount(), expectedTokenAmount);
            assertEq(lbp.initialCurrencyAmount(), currencyAmount);
            assertEq(ERC20(DAI).balanceOf(address(lbp)), currencyAmount);
        } else if (!isValidPrice) {
            // Should revert with InvalidPrice
            vm.expectRevert(abi.encodeWithSelector(ILBPStrategyBasic.InvalidPrice.selector, priceX192));
            lbp.fetchPriceAndCurrencyFromAuction();
        } else {
            // Should revert with InvalidTokenAmount
            vm.expectRevert(
                abi.encodeWithSelector(
                    ILBPStrategyBasic.InvalidTokenAmount.selector, expectedTokenAmount, lbp.reserveSupply()
                )
            );
            lbp.fetchPriceAndCurrencyFromAuction();
        }
    }
}
