// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LBPStrategyBasicTestBase} from "./base/LBPStrategyBasicTestBase.sol";
import "./helpers/LBPTestHelpers.sol";
import {ILBPStrategyBasic} from "../../src/interfaces/ILBPStrategyBasic.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IAuction} from "twap-auction/src/interfaces/IAuction.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {TokenPricing} from "../../src/libraries/TokenPricing.sol";
import {InverseHelpers} from "../shared/InverseHelpers.sol";
import "forge-std/console2.sol";

// Mock auction contract that transfers ETH when sweepCurrency is called
contract MockAuctionWithSweep {
    uint256 immutable ethToTransfer;
    uint64 public immutable endBlock;

    constructor(uint256 _ethToTransfer, uint64 _endBlock) {
        ethToTransfer = _ethToTransfer;
        endBlock = _endBlock;
    }
}

// Mock auction contract that transfers ERC20 when sweepCurrency is called
contract MockAuctionWithERC20Sweep {
    address immutable tokenToTransfer;
    uint256 immutable amountToTransfer;
    uint64 public immutable endBlock;

    constructor(address _token, uint256 _amount, uint64 _endBlock) {
        tokenToTransfer = _token;
        amountToTransfer = _amount;
        endBlock = _endBlock;
    }
}

contract LBPStrategyBasicMigrationTest is LBPStrategyBasicTestBase {
    uint256 constant Q192 = 2 ** 192;

    // ============ Migration Timing Tests ============

    function test_migrate_revertsWithMigrationNotAllowed() public {
        vm.expectRevert(
            abi.encodeWithSelector(ILBPStrategyBasic.MigrationNotAllowed.selector, lbp.migrationBlock(), block.number)
        );
        lbp.migrate();
    }

    function test_migrate_revertsWithAlreadyInitialized() public {
        // Setup and perform first migration
        _setupForMigration(DEFAULT_TOTAL_SUPPLY / 2, 500e18);
        migrateToMigrationBlock(lbp);

        // Try to migrate again
        deal(address(token), address(lbp), DEFAULT_TOTAL_SUPPLY);
        vm.deal(address(lbp), 500e18);
        vm.expectRevert(abi.encodeWithSelector(Pool.PoolAlreadyInitialized.selector));
        lbp.migrate();
    }

    function test_migrate_reverts_whenPriceIsZero() public {
        // Send tokens but don't set initial price
        sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

        MockAuctionWithSweep mockAuction = new MockAuctionWithSweep(0, uint64(block.number));
        vm.deal(address(lbp.auction()), 0);
        vm.etch(address(lbp.auction()), address(mockAuction).code);

        // Mock clearingPrice after etching
        mockAuctionClearingPrice(lbp, 0);
        mockCurrencyRaised(lbp, 0);

        vm.roll(lbp.migrationBlock());
        vm.prank(address(tokenLauncher));
        vm.expectRevert();
        lbp.migrate();
    }

    function test_migrate_token_reverts_whenPriceIsZero() public {
        setupWithCurrency(DAI);
        // Send tokens but don't set initial price
        sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

        MockAuctionWithERC20Sweep mockAuction = new MockAuctionWithERC20Sweep(DAI, 0, uint64(block.number));
        vm.etch(address(lbp.auction()), address(mockAuction).code);

        // Mock clearingPrice after etching
        mockAuctionClearingPrice(lbp, 0);
        mockCurrencyRaised(lbp, 0);

        vm.roll(lbp.migrationBlock());
        vm.prank(address(tokenLauncher));
        vm.expectRevert(abi.encodeWithSelector(TokenPricing.InvalidPrice.selector, 0));
        lbp.migrate();
    }

    function test_migrate_revertsWithInvalidPrice_tooLow() public {
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
        MockAuctionWithERC20Sweep mockAuction = new MockAuctionWithERC20Sweep(DAI, daiAmount, uint64(block.number - 1));
        vm.etch(address(lbp.auction()), address(mockAuction).code);

        // After etching, we need to deal DAI to the auction since vm.etch doesn't preserve balances
        deal(DAI, address(lbp.auction()), daiAmount);

        // Mock the clearingPrice again after etching
        mockAuctionClearingPrice(lbp, veryLowPrice);

        mockCurrencyRaised(lbp, daiAmount);

        deal(DAI, address(lbp), daiAmount);

        vm.roll(lbp.migrationBlock());

        // Expect revert with InvalidPrice
        vm.prank(address(lbp.auction()));
        vm.expectRevert(abi.encodeWithSelector(TokenPricing.InvalidPrice.selector, veryLowPrice));
        lbp.migrate();
    }

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

    // ============ Full Range Migration Tests ============

    function test_migrate_fullRange_withETH_succeeds() public {
        uint128 tokenAmount = DEFAULT_TOTAL_SUPPLY / 2;
        uint128 ethAmount = 500e18;

        // Setup
        _setupForMigration(tokenAmount, ethAmount);

        // Take balance snapshot
        BalanceSnapshot memory before = takeBalanceSnapshot(
            address(token),
            address(0), // ETH
            POSITION_MANAGER,
            POOL_MANAGER,
            address(3)
        );

        // Migrate
        migrateToMigrationBlock(lbp);

        // Take balance snapshot after
        BalanceSnapshot memory afterMigration =
            takeBalanceSnapshot(address(token), address(0), POSITION_MANAGER, POOL_MANAGER, address(3));

        // Verify position created
        assertPositionCreated(
            IPositionManager(POSITION_MANAGER),
            nextTokenId,
            address(0), // currency0 (ETH)
            address(token), // currency1
            500, // poolLPFee
            1, // poolTickSpacing
            TickMath.MIN_TICK,
            TickMath.MAX_TICK
        );

        // Verify balances
        assertLBPStateAfterMigration(lbp, address(token), address(0));
        assertBalancesAfterMigration(before, afterMigration);
    }

    function test_migrate_fullRange_withNonETHCurrency_succeeds() public {
        // Setup with DAI
        setupWithCurrency(DAI);

        uint128 daiAmount = DEFAULT_TOTAL_SUPPLY / 2;

        // Setup for migration
        sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

        // Set up auction with price and currency
        mockAuctionClearingPrice(lbp, 1 << 96);

        // Use a past block for endBlock
        uint64 pastEndBlock = uint64(block.number - 1);

        // Deploy mock auction that handles ERC20 sweepCurrency
        MockAuctionWithERC20Sweep mockAuction = new MockAuctionWithERC20Sweep(DAI, daiAmount, pastEndBlock);
        deal(DAI, address(lbp.auction()), daiAmount);
        vm.etch(address(lbp.auction()), address(mockAuction).code);

        // Mock clearingPrice after etching
        mockAuctionClearingPrice(lbp, 1 << 96);
        mockCurrencyRaised(lbp, daiAmount);

        deal(DAI, address(lbp), daiAmount);

        // Take balance snapshot
        BalanceSnapshot memory before =
            takeBalanceSnapshot(address(token), DAI, POSITION_MANAGER, POOL_MANAGER, address(3));

        // Migrate
        migrateToMigrationBlock(lbp);

        // Take balance snapshot after
        BalanceSnapshot memory afterMigration =
            takeBalanceSnapshot(address(token), DAI, POSITION_MANAGER, POOL_MANAGER, address(3));

        // Verify position
        assertPositionCreated(
            IPositionManager(POSITION_MANAGER),
            nextTokenId,
            address(token), // currency0
            DAI, // currency1
            500, // poolLPFee
            1, // poolTickSpacing
            TickMath.MIN_TICK,
            TickMath.MAX_TICK
        );

        // Verify balances
        assertLBPStateAfterMigration(lbp, address(token), DAI);
        assertBalancesAfterMigration(before, afterMigration);
    }

    // ============ One-Sided Position Migration Tests ============

    function test_migrate_withOneSidedPosition_withETH_succeeds() public {
        uint128 ethAmount = 500e18;
        uint128 tokenAmount = lbp.reserveSupply() / 2; // 250e18

        // Setup
        sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);
        // Set up auction with price and currency
        uint256 pricePerToken = FullMath.mulDiv(ethAmount, 1 << 96, tokenAmount);
        mockAuctionClearingPrice(lbp, pricePerToken);

        // Use a past block for endBlock
        uint64 pastEndBlock = uint64(block.number - 1);

        // Deploy mock auction that handles sweepCurrency
        MockAuctionWithSweep mockAuction = new MockAuctionWithSweep(ethAmount, pastEndBlock);
        vm.deal(address(lbp.auction()), ethAmount);
        vm.etch(address(lbp.auction()), address(mockAuction).code);

        // Mock clearingPrice after etching
        mockAuctionClearingPrice(lbp, pricePerToken);
        mockCurrencyRaised(lbp, ethAmount);

        deal(address(lbp), ethAmount);

        // Take balance snapshot
        BalanceSnapshot memory before =
            takeBalanceSnapshot(address(token), address(0), POSITION_MANAGER, POOL_MANAGER, address(3));

        // Migrate
        migrateToMigrationBlock(lbp);

        // Take balance snapshot after
        BalanceSnapshot memory afterMigration =
            takeBalanceSnapshot(address(token), address(0), POSITION_MANAGER, POOL_MANAGER, address(3));

        // Verify main position
        assertPositionCreated(
            IPositionManager(POSITION_MANAGER),
            nextTokenId,
            address(0),
            address(token),
            500, // poolLPFee
            1, // poolTickSpacing
            TickMath.MIN_TICK,
            TickMath.MAX_TICK
        );

        pricePerToken = FullMath.mulDiv(1 << 96, 1 << 96, pricePerToken);
        uint160 sqrtPriceX96 = uint160(Math.sqrt(pricePerToken << 96));

        // Verify one-sided position
        assertPositionCreated(
            IPositionManager(POSITION_MANAGER),
            nextTokenId + 1,
            address(0),
            address(token),
            500, // poolLPFee
            1, // poolTickSpacing
            TickMath.MIN_TICK,
            TickMath.getTickAtSqrtPrice(sqrtPriceX96)
        );

        // Verify balances
        assertLBPStateAfterMigration(lbp, address(token), address(0));
        assertBalancesAfterMigration(before, afterMigration);
    }

    function test_migrate_withOneSidedPosition_withNonETHCurrency_succeeds() public {
        // Setup with DAI and larger tick spacing
        migratorParams = createMigratorParams(
            DAI,
            500,
            20,
            DEFAULT_TOKEN_SPLIT,
            address(3),
            uint64(block.number + 500),
            uint64(block.number + 1_000),
            address(this),
            true
        );
        _deployLBPStrategy(DEFAULT_TOTAL_SUPPLY);

        uint128 daiAmount = DEFAULT_TOTAL_SUPPLY / 2; // 500e18
        uint128 tokenAmount = lbp.reserveSupply() / 2; // 250e18

        // Setup for migration
        sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

        // Set up auction with price that will create one-sided position
        uint256 pricePerToken = FullMath.mulDiv(daiAmount, 1 << 96, tokenAmount);
        mockAuctionClearingPrice(lbp, pricePerToken);

        // Use a past block for endBlock
        uint64 pastEndBlock = uint64(block.number - 1);

        // Deploy mock auction that handles ERC20 sweepCurrency
        MockAuctionWithERC20Sweep mockAuction = new MockAuctionWithERC20Sweep(DAI, daiAmount, pastEndBlock);
        deal(DAI, address(lbp.auction()), daiAmount);
        vm.etch(address(lbp.auction()), address(mockAuction).code);

        // Mock clearingPrice after etching
        mockAuctionClearingPrice(lbp, pricePerToken);
        mockCurrencyRaised(lbp, daiAmount);

        deal(DAI, address(lbp), daiAmount);

        // Migrate
        migrateToMigrationBlock(lbp);

        // Verify main position
        assertPositionCreated(
            IPositionManager(POSITION_MANAGER), nextTokenId, address(token), DAI, 500, 20, -887260, 887260
        );

        // Verify one-sided position
        assertPositionCreated(
            IPositionManager(POSITION_MANAGER), nextTokenId + 1, address(token), DAI, 500, 20, 6940, 887260
        );

        // Verify balances
        assertLBPStateAfterMigration(lbp, address(token), DAI);
    }

    // ============ Helper Functions ============

    function _setupForMigration(uint128 tokenAmount, uint128 currencyAmount) private {
        sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

        // Set up auction with price
        // The clearing price from the auction is in Q96 format (currencyPerToken * 2^96)
        // For equal amounts, we want price = currencyAmount/tokenAmount * 2^96
        uint256 pricePerToken = FullMath.mulDiv(currencyAmount, 1 << 96, tokenAmount);

        // Use a past block for endBlock
        uint64 pastEndBlock = uint64(block.number - 1);

        // Set up mock auction with currency based on currency type
        if (lbp.currency() == address(0)) {
            // For ETH: Deploy mock auction that handles sweepCurrency
            MockAuctionWithSweep mockAuction = new MockAuctionWithSweep(currencyAmount, pastEndBlock);
            vm.deal(address(lbp.auction()), currencyAmount);
            vm.etch(address(lbp.auction()), address(mockAuction).code);
        } else {
            // For ERC20: Deploy mock auction that handles sweepCurrency
            MockAuctionWithERC20Sweep mockAuction =
                new MockAuctionWithERC20Sweep(lbp.currency(), currencyAmount, pastEndBlock);
            deal(lbp.currency(), address(lbp.auction()), currencyAmount);
            vm.etch(address(lbp.auction()), address(mockAuction).code);
        }

        // Mock the clearing price - already in Q96 format
        mockAuctionClearingPrice(lbp, pricePerToken);
        mockCurrencyRaised(lbp, currencyAmount);

        vm.deal(address(lbp), currencyAmount);
    }

    // Fuzz tests

    function test_fuzz_migrate_ensuresTicksAreMultiplesOfTickSpacing_withETH(int24 tickSpacing) public {
        // Bound inputs to reasonable values
        tickSpacing = int24(bound(tickSpacing, TickMath.MIN_TICK_SPACING, TickMath.MAX_TICK_SPACING));

        //Redeploy with fuzzed tick spacing
        migratorParams = createMigratorParams(
            address(0), // ETH as currency
            500, // fee
            tickSpacing,
            DEFAULT_TOKEN_SPLIT,
            address(3), // position recipient
            uint64(block.number + 500),
            uint64(block.number + 1_000), // sweep block
            address(this), // operator
            true
        );
        _deployLBPStrategy(DEFAULT_TOTAL_SUPPLY);

        uint128 ethAmount = 500e18;
        uint128 tokenAmount = lbp.reserveSupply() / 2; // 250e18

        // Setup
        sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);
        // Set up auction with price and currency
        uint256 pricePerToken = FullMath.mulDiv(ethAmount, 1 << 96, tokenAmount);
        mockAuctionClearingPrice(lbp, pricePerToken);

        // Use a past block for endBlock
        uint64 pastEndBlock = uint64(block.number - 1);

        // Deploy mock auction that handles sweepCurrency
        MockAuctionWithSweep mockAuction = new MockAuctionWithSweep(ethAmount, pastEndBlock);
        vm.deal(address(lbp.auction()), ethAmount);
        vm.etch(address(lbp.auction()), address(mockAuction).code);

        // Mock clearingPrice after etching
        mockAuctionClearingPrice(lbp, pricePerToken);
        mockCurrencyRaised(lbp, ethAmount);
        deal(address(lbp), ethAmount);

        // Migrate
        migrateToMigrationBlock(lbp);

        // Check main position
        (, PositionInfo info) = IPositionManager(POSITION_MANAGER).getPoolAndPositionInfo(nextTokenId);

        // For full range positions, MIN_TICK and MAX_TICK must be multiples of tick spacing
        int24 expectedMinTick = TickMath.MIN_TICK / tickSpacing * tickSpacing;
        int24 expectedMaxTick = TickMath.MAX_TICK / tickSpacing * tickSpacing;

        assertEq(info.tickLower(), expectedMinTick);
        assertEq(info.tickUpper(), expectedMaxTick);

        // Verify they are actually multiples
        assertEq(info.tickLower() % tickSpacing, 0);
        assertEq(info.tickUpper() % tickSpacing, 0);

        // One-sided position should have been created
        (, PositionInfo oneSidedInfo) = IPositionManager(POSITION_MANAGER).getPoolAndPositionInfo(nextTokenId + 1);

        // Verify one-sided position ticks are multiples of tick spacing
        assertEq(oneSidedInfo.tickLower() % tickSpacing, 0);
        assertEq(oneSidedInfo.tickUpper() % tickSpacing, 0);

        pricePerToken = FullMath.mulDiv(1 << 96, 1 << 96, pricePerToken);
        uint160 sqrtPriceX96 = uint160(Math.sqrt(pricePerToken << 96));

        // Additional checks based on currency ordering
        int24 initialTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);

        // ETH < Token: one-sided position should be [MIN_TICK, initialTick)
        assertEq(oneSidedInfo.tickLower(), expectedMinTick);
        // Upper tick should be initialTick floored to tick spacing
        int24 expectedUpperTick = initialTick / tickSpacing * tickSpacing;
        if (initialTick < 0 && initialTick % tickSpacing != 0) {
            expectedUpperTick -= tickSpacing;
        }
        assertEq(oneSidedInfo.tickUpper(), expectedUpperTick);
        assertLe(oneSidedInfo.tickUpper(), initialTick);
    }

    function test_fuzz_migrate_withNonETHCurrency_ensuresTicksAreMultiplesOfTickSpacing(int24 tickSpacing) public {
        // Bound inputs to reasonable values
        tickSpacing = int24(bound(tickSpacing, TickMath.MIN_TICK_SPACING, TickMath.MAX_TICK_SPACING));

        // Redeploy with fuzzed tick spacing
        migratorParams = createMigratorParams(
            DAI,
            500,
            tickSpacing,
            DEFAULT_TOKEN_SPLIT,
            address(3),
            uint64(block.number + 500),
            uint64(block.number + 1_000),
            address(this),
            true
        );
        _deployLBPStrategy(DEFAULT_TOTAL_SUPPLY);

        uint128 daiAmount = DEFAULT_TOTAL_SUPPLY / 2;
        uint128 tokenAmount = lbp.reserveSupply() / 2;

        // Setup for migration
        sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

        // Set up auction with price that will create one-sided position
        uint256 pricePerToken = FullMath.mulDiv(daiAmount, 1 << 96, tokenAmount);
        mockAuctionClearingPrice(lbp, pricePerToken);

        // Use a past block for endBlock
        uint64 pastEndBlock = uint64(block.number - 1);

        // Deploy mock auction that handles ERC20 sweepCurrency
        MockAuctionWithERC20Sweep mockAuction = new MockAuctionWithERC20Sweep(DAI, daiAmount, pastEndBlock);
        deal(DAI, address(lbp.auction()), daiAmount);
        vm.etch(address(lbp.auction()), address(mockAuction).code);

        // Mock clearingPrice after etching
        mockAuctionClearingPrice(lbp, pricePerToken);
        mockCurrencyRaised(lbp, daiAmount);
        deal(DAI, address(lbp), daiAmount);

        // Migrate
        migrateToMigrationBlock(lbp);

        // Check main position
        (, PositionInfo info) = IPositionManager(POSITION_MANAGER).getPoolAndPositionInfo(nextTokenId);

        // For full range positions, MIN_TICK and MAX_TICK must be multiples of tick spacing
        int24 expectedMinTick = TickMath.MIN_TICK / tickSpacing * tickSpacing;
        int24 expectedMaxTick = TickMath.MAX_TICK / tickSpacing * tickSpacing;

        assertEq(info.tickLower(), expectedMinTick);
        assertEq(info.tickUpper(), expectedMaxTick);

        // Verify they are actually multiples
        assertEq(info.tickLower() % tickSpacing, 0);
        assertEq(info.tickUpper() % tickSpacing, 0);

        // One-sided position should have been created
        (, PositionInfo oneSidedInfo) = IPositionManager(POSITION_MANAGER).getPoolAndPositionInfo(nextTokenId + 1);

        // Verify one-sided position ticks are multiples of tick spacing
        assertEq(oneSidedInfo.tickLower() % tickSpacing, 0);
        assertEq(oneSidedInfo.tickUpper() % tickSpacing, 0);

        pricePerToken = FullMath.mulDiv(1 << 96, 1 << 96, pricePerToken);
        uint160 sqrtPriceX96 = uint160(Math.sqrt(pricePerToken << 96));

        // Additional checks based on currency ordering
        int24 initialTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);

        // Token < Currency: one-sided position should be (initialTick, MAX_TICK]
        assertEq(oneSidedInfo.tickUpper(), expectedMaxTick);
        assertGt(oneSidedInfo.tickLower(), initialTick);
    }

    /// @notice Tests validate with fuzzed inputs
    /// @dev This test checks various price and currency amount combinations
    function test_fuzz_migrate_withETH(uint256 pricePerToken, uint128 ethAmount, uint16 tokenSplit) public {
        vm.assume(pricePerToken <= type(uint160).max);
        tokenSplit = uint16(bound(tokenSplit, 1, 10_000));

        migratorParams = createMigratorParams(
            address(0),
            500,
            20,
            tokenSplit,
            address(3),
            uint64(block.number + 500),
            uint64(block.number + 1_000),
            address(this),
            true
        );
        _deployLBPStrategy(DEFAULT_TOTAL_SUPPLY);

        // Setup
        sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

        // Mock auction functions
        mockAuctionClearingPrice(lbp, pricePerToken);
        mockAuctionEndBlock(lbp, uint64(block.number - 1));

        // Deploy and etch mock auction
        MockAuctionWithSweep mockAuction = new MockAuctionWithSweep(ethAmount, uint64(block.number - 1));
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
        bool tokenAmountFitsInUint128 = expectedTokenAmount <= type(uint128).max;

        // Check if the price is within valid bounds
        bool isValidPrice = expectedSqrtPrice >= TickMath.MIN_SQRT_PRICE && expectedSqrtPrice <= TickMath.MAX_SQRT_PRICE;

        bool isLeftoverToken = expectedTokenAmount <= lbp.reserveSupply();

        vm.roll(lbp.migrationBlock());

        if (!isValidPrice && pricePerToken != 0) {
            // Should revert with InvalidPrice
            vm.prank(address(lbp.auction()));
            vm.expectRevert(abi.encodeWithSelector(TokenPricing.InvalidPrice.selector, pricePerToken));
            lbp.migrate();
        } else if (isLeftoverToken) {
            if (pricePerToken == 0) {
                vm.expectRevert();
                lbp.migrate();
            } else {
                // corresponding token amt greater than allowed
                if (FullMath.mulDiv(lbp.reserveSupply(), Q192, priceX192) > type(uint128).max) {
                    vm.prank(address(lbp.auction()));
                    vm.expectRevert();
                    lbp.migrate();
                }
            }
        }
    }

    function test_migrate_withETH_revertsWithPriceTooHigh() public {
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
        MockAuctionWithSweep mockAuction = new MockAuctionWithSweep(ethAmount, uint64(block.number - 1));
        vm.deal(address(lbp.auction()), ethAmount);
        vm.etch(address(lbp.auction()), address(mockAuction).code);

        // Mock the clearingPrice again after etching
        mockAuctionClearingPrice(lbp, veryLowClearingPrice);

        mockCurrencyRaised(lbp, ethAmount);

        deal(address(lbp), ethAmount);

        // Calculate the inverted price that will be used in the contract
        uint256 invertedPrice = InverseHelpers.invertPrice(veryLowClearingPrice);

        vm.roll(lbp.migrationBlock());

        vm.prank(address(lbp.auction()));
        // Expect revert with InvalidPrice (the error will contain the inverted price)
        vm.expectRevert(abi.encodeWithSelector(TokenPricing.InvalidPrice.selector, invertedPrice));
        lbp.migrate();
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
        MockAuctionWithERC20Sweep mockAuction =
            new MockAuctionWithERC20Sweep(DAI, currencyAmount, uint64(block.number - 1));
        vm.etch(address(lbp.auction()), address(mockAuction).code);

        // After etching, we need to deal DAI to the auction since vm.etch doesn't preserve balances
        deal(DAI, address(lbp.auction()), currencyAmount);

        // Mock the clearingPrice again after etching
        mockAuctionClearingPrice(lbp, pricePerToken);

        mockCurrencyRaised(lbp, currencyAmount);
        deal(DAI, address(lbp), currencyAmount);

        vm.roll(lbp.migrationBlock());

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
            lbp.migrate();
        } else if (!tokenAmountFitsInUint128) {
            // Should revert with InvalidTokenAmount
            vm.prank(address(lbp.auction()));
            vm.expectRevert();
            lbp.migrate();
        }
    }
}
