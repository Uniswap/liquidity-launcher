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
import {ICheckpointStorage} from "twap-auction/src/interfaces/ICheckpointStorage.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {TokenPricing} from "../../src/libraries/TokenPricing.sol";
import {InverseHelpers} from "../shared/InverseHelpers.sol";
import {Checkpoint, ValueX7} from "twap-auction/src/libraries/CheckpointLib.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {ITokenCurrencyStorage} from "twap-auction/src/interfaces/ITokenCurrencyStorage.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {TokenDistribution} from "../../src/libraries/TokenDistribution.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

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
    using TokenDistribution for uint128;
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
        sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);
        IAuction realAuction = lbp.auction();

        // Submit bids and checkpoint auction
        vm.roll(realAuction.startBlock());
        _submitBid(
            realAuction,
            alice,
            inputAmountForTokens(250e18, tickNumberToPriceX96(2)),
            tickNumberToPriceX96(2),
            tickNumberToPriceX96(1),
            0
        );

        _submitBid(
            realAuction,
            bob,
            inputAmountForTokens(250e18, tickNumberToPriceX96(2)),
            tickNumberToPriceX96(2),
            tickNumberToPriceX96(1),
            1
        );

        vm.roll(realAuction.endBlock());
        realAuction.checkpoint();

        // sweepCurrency sends to the fundsRecipient which is the lbp
        realAuction.sweepCurrency();

        // Perform first migration
        vm.roll(lbp.migrationBlock());
        lbp.migrate();

        // Try to migrate again
        // give lbp more tokens and currency for testing purposes
        deal(address(token), address(lbp), lbp.reserveSupply());
        vm.deal(address(lbp), realAuction.currencyRaised());
        vm.expectRevert(abi.encodeWithSelector(Pool.PoolAlreadyInitialized.selector));
        lbp.migrate();
    }

    function test_migrate_reverts_whenNoCurrencyRaised() public {
        // Send tokens but don't submit any bids
        sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

        IAuction realAuction = lbp.auction();

        // Move to end of auction without any bids
        vm.roll(realAuction.endBlock());
        realAuction.checkpoint();

        // The auction should have floor price as clearing price with no bids
        uint256 clearingPrice = ICheckpointStorage(address(realAuction)).clearingPrice();
        assertEq(clearingPrice, FLOOR_PRICE);

        realAuction.sweepCurrency();

        vm.roll(lbp.migrationBlock());
        vm.expectRevert(abi.encodeWithSelector(ILBPStrategyBasic.NoCurrencyRaised.selector));
        lbp.migrate();
    }

    function test_migrate_token_reverts_whenNoCurrencyRaised() public {
        setupWithCurrency(DAI);
        // Send tokens but don't submit any bids
        sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

        IAuction realAuction = lbp.auction();

        // Move to end of auction without any bids
        vm.roll(realAuction.endBlock());
        realAuction.checkpoint();

        // The auction should have floor price as clearing price with no bids
        uint256 clearingPrice = ICheckpointStorage(address(realAuction)).clearingPrice();
        assertEq(clearingPrice, FLOOR_PRICE);

        realAuction.sweepCurrency();

        vm.roll(lbp.migrationBlock());
        // No currency was raised, so auction did not graduate
        vm.expectRevert(abi.encodeWithSelector(ILBPStrategyBasic.NoCurrencyRaised.selector));
        lbp.migrate();
    }

    function test_migrate_revertsWithPriceIsZero() public {
        // Setup with DAI as currency1
        setupWithCurrency(DAI);

        // Setup: Send tokens to LBP and create auction
        sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

        uint128 daiAmount = DEFAULT_TOTAL_SUPPLY / 2;

        // Mock a very low price that will result in sqrtPrice below MIN_SQRT_PRICE
        // would never happen because the floor price is 1 << 33
        uint256 veryLowPrice = 0;
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

        mockAuctionCheckpoint(
            lbp,
            Checkpoint({
                clearingPrice: veryLowPrice,
                currencyRaisedAtClearingPriceQ96_X7: ValueX7.wrap(0),
                cumulativeMpsPerPrice: 0,
                cumulativeMps: 0,
                prev: 0,
                next: type(uint64).max
            })
        );

        // Expect revert with PriceIsZero
        vm.prank(address(lbp.auction()));
        vm.expectRevert(abi.encodeWithSelector(TokenPricing.PriceIsZero.selector, veryLowPrice));
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

    /// forge-config: default.allow_internal_expect_revert = true
    function test_migrate_liquidityDoesNotRevert(
        uint256 clearingPrice,
        int24 tickSpacing,
        uint128 amount0,
        uint128 amount1
    ) public {
        clearingPrice = uint256(bound(clearingPrice, 2 ** 32 + 1, type(uint256).max));
        tickSpacing = int24(bound(tickSpacing, TickMath.MIN_TICK_SPACING, TickMath.MAX_TICK_SPACING));
        amount0 = uint128(bound(amount0, 1, type(uint128).max));
        amount1 = uint128(bound(amount1, 1, 1e30));

        uint256 priceX192 = TokenPricing.convertToPriceX192(clearingPrice, true);
        uint160 sqrtPriceX96 = uint160(Math.sqrt(priceX192));
        vm.assume(sqrtPriceX96 > TickMath.MIN_SQRT_PRICE && sqrtPriceX96 < TickMath.MAX_SQRT_PRICE);

        // Setup
        // 1000 total supply, 500 auction supply, 500 reserve supply
        sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

        uint128 tokenAmount = uint128(uint256(DEFAULT_TOTAL_SUPPLY) * uint256(DEFAULT_TOKEN_SPLIT) / 1e7);

        mockAuctionClearingPrice(lbp, clearingPrice);
        mockAuctionEndBlock(lbp, uint64(block.number - 1));
        mockCurrencyRaised(lbp, FullMath.mulDiv(tokenAmount, clearingPrice, 2 ** 96));
        deal(address(lbp), FullMath.mulDiv(tokenAmount, clearingPrice, 2 ** 96));

        mockAuctionCheckpoint(
            lbp,
            Checkpoint({
                clearingPrice: clearingPrice,
                currencyRaisedAtClearingPriceQ96_X7: ValueX7.wrap(FullMath.mulDiv(tokenAmount, clearingPrice, 2 ** 96)),
                cumulativeMpsPerPrice: 0,
                cumulativeMps: 0,
                prev: 0,
                next: type(uint64).max
            })
        );

        // Migrate
        vm.roll(lbp.migrationBlock());

        if (
            FullMath.mulDiv(amount0, FixedPoint96.Q96, TickMath.getSqrtPriceAtTick(TickMath.MAX_TICK) - sqrtPriceX96)
                > type(uint128).max
        ) {
            vm.expectRevert();
            lbp.migrate();
        } else {
            lbp.migrate();
        }
    }

    // ============ Full Range Migration Tests ============

    function test_migrate_fullRange_withETH_succeeds() public {
        // Setup
        // 1000 total supply, 500 auction supply, 500 reserve supply
        sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

        IAuction realAuction = lbp.auction();
        assertFalse(address(realAuction) == address(0));

        // Move to auction start
        vm.roll(realAuction.startBlock());

        // Submit bids at a valid tick price
        uint256 targetPrice = tickNumberToPriceX96(2); // floor price + 1 tick

        _submitBid(
            realAuction,
            alice,
            inputAmountForTokens(250e18, targetPrice), // 250 tokens at max target price
            targetPrice,
            tickNumberToPriceX96(1), // prev price is floor price
            0
        );

        _submitBid(
            realAuction,
            bob,
            inputAmountForTokens(250e18, targetPrice), // 250 tokens at max target price
            targetPrice,
            tickNumberToPriceX96(1), // prev price is floor price
            1
        );

        // Take balance snapshot
        BalanceSnapshot memory before = takeBalanceSnapshot(
            address(token),
            address(0), // ETH
            POSITION_MANAGER,
            POOL_MANAGER,
            address(3)
        );

        vm.roll(realAuction.endBlock());
        realAuction.checkpoint();

        realAuction.sweepCurrency();

        // Migrate
        vm.roll(lbp.migrationBlock());
        lbp.migrate();

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
        createAuctionParamsWithCurrency(DAI);
        setupWithCurrency(DAI);
        sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

        IAuction realAuction = lbp.auction();
        assertFalse(address(realAuction) == address(0));

        // Move to auction start
        vm.roll(realAuction.startBlock());

        // Submit bids with DAI at a valid tick price
        uint256 targetPrice = tickNumberToPriceX96(2);

        // Deal DAI and submit bids for alice
        uint128 daiAmount = inputAmountForTokens(250e18, targetPrice);
        deal(DAI, alice, daiAmount);
        vm.prank(alice);
        ERC20(DAI).approve(address(PERMIT2), daiAmount);
        vm.prank(alice);
        IAllowanceTransfer(PERMIT2)
            .approve(DAI, address(realAuction), uint160(daiAmount), uint48(block.timestamp + 1000));

        _submitBidNonEth(realAuction, alice, daiAmount, targetPrice, tickNumberToPriceX96(1), 0);

        // Deal DAI and submit bids for bob
        deal(DAI, bob, daiAmount);
        vm.prank(bob);
        ERC20(DAI).approve(address(PERMIT2), daiAmount);
        vm.prank(bob);
        IAllowanceTransfer(PERMIT2)
            .approve(DAI, address(realAuction), uint160(daiAmount), uint48(block.timestamp + 1000));

        _submitBidNonEth(realAuction, bob, daiAmount, targetPrice, tickNumberToPriceX96(1), 1);

        // Take balance snapshot
        BalanceSnapshot memory before =
            takeBalanceSnapshot(address(token), DAI, POSITION_MANAGER, POOL_MANAGER, address(3));

        vm.roll(realAuction.endBlock());
        realAuction.checkpoint();

        realAuction.sweepCurrency();

        // Migrate
        vm.roll(lbp.migrationBlock());
        lbp.migrate();

        // Take balance snapshot after
        BalanceSnapshot memory afterMigration =
            takeBalanceSnapshot(address(token), DAI, POSITION_MANAGER, POOL_MANAGER, address(3));

        // Verify position created
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

    function test_migrate_noOneSidedPosition_leftoverToken_succeeds() public {
        migratorParams = createMigratorParams(
            address(0),
            500,
            20,
            DEFAULT_TOKEN_SPLIT,
            address(3),
            uint64(block.number + 500),
            uint64(block.number + 1_000),
            testOperator,
            false, // no one-sided position in tokens
            false // no one-sided position in currency
        );
        _deployLBPStrategy(DEFAULT_TOTAL_SUPPLY);
        sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

        IAuction realAuction = lbp.auction();
        assertFalse(address(realAuction) == address(0));

        // Move to auction start
        vm.roll(realAuction.startBlock());

        // ensure leftover tokens
        uint256 highPrice = tickNumberToPriceX96(5);

        _submitBid(realAuction, alice, inputAmountForTokens(500e18, highPrice), highPrice, tickNumberToPriceX96(1), 0);

        _submitBid(realAuction, bob, inputAmountForTokens(500e18, highPrice), highPrice, tickNumberToPriceX96(1), 1);

        vm.roll(realAuction.endBlock());
        realAuction.checkpoint();

        realAuction.sweepCurrency();

        // Take balance snapshot
        BalanceSnapshot memory before =
            takeBalanceSnapshot(address(token), address(0), POSITION_MANAGER, POOL_MANAGER, address(3));

        // Migrate
        vm.roll(lbp.migrationBlock());
        lbp.migrate();

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
            20, // poolTickSpacing
            TickMath.MIN_TICK / 20 * 20,
            TickMath.MAX_TICK / 20 * 20
        );

        // Verify one-sided position is not created
        assertPositionNotCreated(IPositionManager(POSITION_MANAGER), nextTokenId + 1);

        // Verify balances
        assertBalancesAfterMigration(before, afterMigration);
        // leftover tokens, no leftover currency
        assertGt(Currency.wrap(address(token)).balanceOf(address(lbp)), 0);
        assertLe(Currency.wrap(address(0)).balanceOf(address(lbp)), LBPTestHelpers.DUST_AMOUNT); // dust

        uint256 operatorBalanceBefore = Currency.wrap(address(token)).balanceOf(lbp.operator());

        vm.roll(lbp.sweepBlock());
        vm.prank(lbp.operator());
        lbp.sweepToken();
        assertEq(Currency.wrap(address(token)).balanceOf(address(lbp)), 0);
        assertGt(Currency.wrap(address(token)).balanceOf(lbp.operator()), operatorBalanceBefore);
    }

    function test_migrate_noOneSidedPosition_leftoverCurrency_succeeds() public {
        migratorParams = createMigratorParams(
            address(0),
            500,
            20,
            8e6, // 80% of the total supply to the auction (800 tokens)
            address(3),
            uint64(block.number + 500),
            uint64(block.number + 1_000),
            testOperator,
            false, // no one-sided position in tokens
            false // no one-sided position in currency
        );
        _deployLBPStrategy(DEFAULT_TOTAL_SUPPLY);
        sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

        IAuction realAuction = lbp.auction();
        assertFalse(address(realAuction) == address(0));

        // Move to auction start
        vm.roll(realAuction.startBlock());

        uint256 targetPrice = tickNumberToPriceX96(2);

        _submitBid(
            realAuction, alice, inputAmountForTokens(400e18, targetPrice), targetPrice, tickNumberToPriceX96(1), 0
        );

        _submitBid(realAuction, bob, inputAmountForTokens(400e18, targetPrice), targetPrice, tickNumberToPriceX96(1), 1);

        vm.roll(realAuction.endBlock());
        realAuction.checkpoint();

        realAuction.sweepCurrency();

        // Take balance snapshot
        BalanceSnapshot memory before =
            takeBalanceSnapshot(address(token), address(0), POSITION_MANAGER, POOL_MANAGER, address(3));

        // Migrate
        vm.roll(lbp.migrationBlock());
        lbp.migrate();

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
            20, // poolTickSpacing
            TickMath.MIN_TICK / 20 * 20,
            TickMath.MAX_TICK / 20 * 20
        );

        // Verify one-sided position is not created
        assertPositionNotCreated(IPositionManager(POSITION_MANAGER), nextTokenId + 1);

        // Verify balances
        assertBalancesAfterMigration(before, afterMigration);

        uint256 operatorBalanceBefore = Currency.wrap(address(0)).balanceOf(lbp.operator());
        vm.roll(lbp.sweepBlock());
        vm.prank(lbp.operator());
        lbp.sweepCurrency();
        assertEq(Currency.wrap(address(0)).balanceOf(address(lbp)), 0);
        assertGt(Currency.wrap(address(0)).balanceOf(lbp.operator()), operatorBalanceBefore);
    }

    // ============ One-Sided Position Migration Tests ============

    function test_migrate_withOneSidedPosition_withETH_succeeds() public {
        // Setup
        sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

        IAuction realAuction = lbp.auction();
        assertFalse(address(realAuction) == address(0));

        // Move to auction start
        vm.roll(realAuction.startBlock());

        uint256 targetPrice = tickNumberToPriceX96(5);

        _submitBid(
            realAuction, alice, inputAmountForTokens(5000e18, targetPrice), targetPrice, tickNumberToPriceX96(1), 0
        );

        _submitBid(realAuction, bob, inputAmountForTokens(500e18, targetPrice), targetPrice, tickNumberToPriceX96(1), 1);

        // Take balance snapshot
        BalanceSnapshot memory before =
            takeBalanceSnapshot(address(token), address(0), POSITION_MANAGER, POOL_MANAGER, address(3));

        vm.roll(realAuction.endBlock());
        realAuction.checkpoint();

        // Get clearing price before sweeping
        uint256 clearingPrice = ICheckpointStorage(address(realAuction)).clearingPrice();

        realAuction.sweepCurrency();

        // Migrate
        vm.roll(lbp.migrationBlock());
        lbp.migrate();

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

        // Calculate expected price for one-sided position
        uint256 invertedPrice = FullMath.mulDiv(1 << 96, 1 << 96, clearingPrice);
        uint160 sqrtPriceX96 = uint160(Math.sqrt(invertedPrice << 96));

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
        createAuctionParamsWithCurrency(DAI);
        migratorParams = createMigratorParams(
            DAI,
            500,
            20,
            4e6, // 40% of the total supply to the auction (400 tokens)
            address(3),
            uint64(block.number + 500),
            uint64(block.number + 1_000),
            testOperator,
            true,
            true
        );
        _deployLBPStrategy(DEFAULT_TOTAL_SUPPLY);
        sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

        IAuction realAuction = lbp.auction();
        assertFalse(address(realAuction) == address(0));

        // Move to auction start
        vm.roll(realAuction.startBlock());

        uint256 targetPrice = tickNumberToPriceX96(5);

        uint128 daiAmount = inputAmountForTokens(200e18, targetPrice);
        deal(DAI, alice, daiAmount);
        vm.prank(alice);
        ERC20(DAI).approve(address(PERMIT2), daiAmount);
        vm.prank(alice);
        IAllowanceTransfer(PERMIT2)
            .approve(DAI, address(realAuction), uint160(daiAmount), uint48(block.timestamp + 1000));

        _submitBidNonEth(realAuction, alice, daiAmount, targetPrice, tickNumberToPriceX96(1), 0);

        // Bid for 250e18 tokens
        daiAmount = inputAmountForTokens(200e18, targetPrice);
        deal(DAI, bob, daiAmount);
        vm.prank(bob);
        ERC20(DAI).approve(address(PERMIT2), daiAmount);
        vm.prank(bob);
        IAllowanceTransfer(PERMIT2)
            .approve(DAI, address(realAuction), uint160(daiAmount), uint48(block.timestamp + 1000));

        _submitBidNonEth(realAuction, bob, daiAmount, targetPrice, tickNumberToPriceX96(1), 1);

        vm.roll(realAuction.endBlock());
        realAuction.checkpoint();

        realAuction.sweepCurrency();

        // Migrate
        vm.roll(lbp.migrationBlock());
        lbp.migrate();

        // Verify main position - token (0x1111...) < DAI (0x6B17...) so token is currency0
        assertPositionCreated(
            IPositionManager(POSITION_MANAGER),
            nextTokenId,
            address(token), // currency0
            DAI, // currency1
            500,
            20,
            TickMath.MIN_TICK / 20 * 20,
            TickMath.MAX_TICK / 20 * 20
        );

        // Verify one-sided position
        assertPositionCreated(
            IPositionManager(POSITION_MANAGER),
            nextTokenId + 1,
            address(token), // currency0
            DAI, // currency1
            500,
            20,
            72460,
            TickMath.MAX_TICK / 20 * 20
        );

        // Verify balances
        assertLBPStateAfterMigration(lbp, address(token), DAI);
    }

    // Fuzz tests

    function test_fuzz_migrate_ensuresTicksAreMultiplesOfTickSpacing_withETH(int24 tickSpacing) public {
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
            true,
            true
        );
        _deployLBPStrategy(DEFAULT_TOTAL_SUPPLY);

        sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

        IAuction realAuction = lbp.auction();
        assertFalse(address(realAuction) == address(0));

        // Move to auction start
        vm.roll(realAuction.startBlock());

        // ensure leftover tokens
        uint256 targetPrice = tickNumberToPriceX96(5);

        _submitBid(
            realAuction, alice, inputAmountForTokens(500e18, targetPrice), targetPrice, tickNumberToPriceX96(1), 0
        );

        vm.roll(realAuction.endBlock());
        realAuction.checkpoint();

        uint256 clearingPrice = ICheckpointStorage(address(realAuction)).clearingPrice();

        realAuction.sweepCurrency();

        // Migrate
        vm.roll(lbp.migrationBlock());
        lbp.migrate();

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

        uint256 invertedPrice = FullMath.mulDiv(1 << 96, 1 << 96, clearingPrice);
        uint160 sqrtPriceX96 = uint160(Math.sqrt(invertedPrice << 96));

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

        createAuctionParamsWithCurrency(DAI);

        // Redeploy with fuzzed tick spacing
        migratorParams = createMigratorParams(
            DAI,
            500,
            tickSpacing,
            2e6, // 20% of the total supply to the auction (200 tokens)
            address(3),
            uint64(block.number + 500),
            uint64(block.number + 1_000),
            address(this),
            true,
            true
        );
        _deployLBPStrategy(DEFAULT_TOTAL_SUPPLY);

        sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

        IAuction realAuction = lbp.auction();
        assertFalse(address(realAuction) == address(0));

        // Move to auction start
        vm.roll(realAuction.startBlock());

        uint256 targetPrice = tickNumberToPriceX96(5);

        uint128 daiAmount = inputAmountForTokens(200e18, targetPrice);
        deal(DAI, alice, daiAmount);
        vm.prank(alice);
        ERC20(DAI).approve(address(PERMIT2), daiAmount);
        vm.prank(alice);
        IAllowanceTransfer(PERMIT2)
            .approve(DAI, address(realAuction), uint160(daiAmount), uint48(block.timestamp + 1000));

        _submitBidNonEth(realAuction, alice, daiAmount, targetPrice, tickNumberToPriceX96(1), 0);

        vm.roll(realAuction.endBlock());
        realAuction.checkpoint();

        uint256 clearingPrice = ICheckpointStorage(address(realAuction)).clearingPrice();

        realAuction.sweepCurrency();

        // Migrate
        vm.roll(lbp.migrationBlock());
        lbp.migrate();

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

        // Note: For DAI/Token pair, the price doesn't need to be inverted
        uint160 sqrtPriceX96 = uint160(Math.sqrt(clearingPrice << 96));

        // Additional checks based on currency ordering
        int24 initialTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);

        // Token < Currency: one-sided position should be (initialTick, MAX_TICK]
        assertEq(oneSidedInfo.tickUpper(), expectedMaxTick);
        assertGt(oneSidedInfo.tickLower(), initialTick);
    }

    /// @notice Tests validate with fuzzed inputs
    /// @dev This test checks various price and currency amount combinations
    function test_fuzz_migrate_withETH(uint128 totalSupply, uint24 tokenSplit, uint256 clearingPrice) public {
        tokenSplit = uint24(bound(tokenSplit, 1, 1e7 - 1));
        totalSupply = uint128(bound(totalSupply, 1, type(uint128).max));

        uint128 tokenAmount = uint128(uint256(totalSupply) * uint256(tokenSplit) / 1e7);
        vm.assume(tokenAmount > 0 && tokenAmount <= 1e30);
        uint256 maxClearingPrice = FixedPointMathLib.min(type(uint256).max / totalSupply, 1 << 223);
        clearingPrice = uint256(bound(clearingPrice, 2 ** 32 + 1, maxClearingPrice));

        uint256 inverseClearingPrice = InverseHelpers.inverseQ96(clearingPrice);
        // Ensure that we don't hit cannot update empty position because the amounts round to 0
        uint256 currencyRaised = FullMath.mulDiv(tokenAmount, clearingPrice, 2 ** 96);
        vm.assume(currencyRaised > 0 && currencyRaised <= type(uint128).max);

        uint256 expectedTokenAmount;
        if (lbp.currency() < lbp.token()) {
            expectedTokenAmount = FullMath.mulDiv(tokenAmount, 2 ** 96, inverseClearingPrice);
            vm.assume(expectedTokenAmount > 0);
        } else {
            expectedTokenAmount = FullMath.mulDiv(tokenAmount, clearingPrice, 2 ** 96);
            vm.assume(expectedTokenAmount > 0);
        }

        setupWithSupplyAndTokenSplit(totalSupply, tokenSplit, address(0));

        // Setup
        sendTokensToLBP(address(tokenLauncher), token, lbp, totalSupply);

        mockAuctionClearingPrice(lbp, clearingPrice);
        mockAuctionEndBlock(lbp, uint64(block.number - 1));
        mockCurrencyRaised(lbp, currencyRaised);
        deal(address(lbp), currencyRaised);

        mockAuctionCheckpoint(
            lbp,
            Checkpoint({
                clearingPrice: clearingPrice,
                currencyRaisedAtClearingPriceQ96_X7: ValueX7.wrap(currencyRaised),
                cumulativeMpsPerPrice: 0,
                cumulativeMps: 0,
                prev: 0,
                next: type(uint64).max
            })
        );

        vm.roll(lbp.migrationBlock());

        lbp.migrate();
    }

    function test_WhenAmountsAndClearingPriceWithinBounds(uint128 totalSupply, uint256 clearingPrice, uint24 tokenSplit)
        public
    {
        // it should migrate successfully

        tokenSplit = uint24(bound(tokenSplit, 1, 1e7 - 1));
        uint128 tokenAmount = uint128(uint256(totalSupply) * uint256(tokenSplit) / 1e7);
        vm.assume(tokenAmount > 0 && tokenAmount <= 1e30);

        setupWithSupplyAndTokenSplit(totalSupply, tokenSplit, address(0));
        sendTokensToLBP(address(tokenLauncher), token, lbp, totalSupply);

        uint256 auctionMaxBidPrice = (1 << 203) / tokenAmount;
        clearingPrice = _bound(clearingPrice, 2 ** 33, auctionMaxBidPrice);
        // Calculate currency raised based on the clearingPrice
        uint256 currencyRaised = (tokenAmount * clearingPrice) >> 96;
        vm.assume(currencyRaised > 0 && currencyRaised <= type(uint128).max);

        // In the case where currency is currency0, the price will be inverted
        uint256 invertedClearingPrice = (~uint256(0) / clearingPrice) << 32;
        // And the tokenAmountUint256 calculated with the inverted price
        assertEq(lbp.currency() < lbp.token(), true);
        uint256 expectedTokenAmountUint256 = FullMath.mulDiv(invertedClearingPrice, currencyRaised, Q192);
        // Assume the expected token amount is greater than 0 so the clearing price and currency raised
        // are large enough values
        vm.assume(expectedTokenAmountUint256 > 0);

        MockAuctionWithSweep mockAuction = new MockAuctionWithSweep(currencyRaised, uint64(block.number - 1));
        vm.label(address(mockAuction), "mockAuction");

        vm.deal(address(lbp.auction()), currencyRaised);
        vm.etch(address(lbp.auction()), address(mockAuction).code);

        // Mock the clearingPrice again after etching
        mockAuctionClearingPrice(lbp, clearingPrice);
        mockCurrencyRaised(lbp, currencyRaised);

        vm.deal(address(lbp), currencyRaised);

        mockAuctionCheckpoint(
            lbp,
            Checkpoint({
                clearingPrice: clearingPrice,
                currencyRaisedAtClearingPriceQ96_X7: ValueX7.wrap(currencyRaised),
                cumulativeMpsPerPrice: 0,
                cumulativeMps: 0,
                prev: 0,
                next: type(uint64).max
            })
        );

        vm.roll(lbp.migrationBlock());

        // This should not revert
        lbp.migrate();
    }

    function test_WhenCurrencyIsCurrency0AndTokenAmountUint256RoundsDownToZero(
        uint128 totalSupply,
        uint256 clearingPrice,
        uint24 tokenSplit
    ) public {
        // it should revert with {CannotUpdateEmptyPosition}
        tokenSplit = uint24(bound(tokenSplit, 1, 1e7 - 1));
        uint128 tokenAmount = uint128(uint256(totalSupply) * uint256(tokenSplit) / 1e7);
        vm.assume(tokenAmount > 0 && tokenAmount <= 1e30);

        setupWithSupplyAndTokenSplit(totalSupply, tokenSplit, address(0));
        sendTokensToLBP(address(tokenLauncher), token, lbp, totalSupply);

        // Bound the clearing price to be between 1 and 2 ** 33 - 1
        clearingPrice = _bound(clearingPrice, 1, 2 ** 33 - 1);
        // In the case where currency is currency0, the price will be inverted
        uint256 invertedClearingPrice = (~uint256(0) / clearingPrice) << 32;

        // Very low currencyRaised
        uint256 currencyRaised = 1;

        // Assume that the numerator is < denominator so that the result is zero
        // FullMath.mulDiv(invertedClearingPrice, currencyRaised, Q192) == 0
        vm.assume(invertedClearingPrice < Q192 / currencyRaised);

        MockAuctionWithSweep mockAuction = new MockAuctionWithSweep(currencyRaised, uint64(block.number - 1));
        vm.etch(address(lbp.auction()), address(mockAuction).code);

        vm.deal(address(lbp.auction()), currencyRaised);
        vm.deal(address(lbp), currencyRaised);

        Checkpoint memory checkpoint;
        checkpoint.clearingPrice = clearingPrice;
        mockAuctionClearingPrice(lbp, clearingPrice);
        mockCurrencyRaised(lbp, currencyRaised);
        mockAuctionCheckpoint(lbp, checkpoint);

        vm.roll(lbp.migrationBlock());

        lbp.migrate();
    }

    // To test the case where the inverted currency is too high
    function test_WhenCurrencyIsCurrency0AndClearingPriceIsTooLow(
        uint128 totalSupply,
        uint256 clearingPrice,
        uint24 tokenSplit
    ) public {
        // it should revert with PriceTooHigh

        tokenSplit = uint24(bound(tokenSplit, 1, 1e7 - 1));
        uint128 tokenAmount = uint128(uint256(totalSupply) * uint256(tokenSplit) / 1e7);
        vm.assume(tokenAmount > 0 && tokenAmount <= 1e30);

        setupWithSupplyAndTokenSplit(totalSupply, tokenSplit, address(0));
        sendTokensToLBP(address(tokenLauncher), token, lbp, totalSupply);

        // Bound the clearing price to be between 1 and 2 ** 32 - 1
        // Since the inverse has to fit within uint160, uint192 / uint32 > uint160
        clearingPrice = _bound(clearingPrice, 1, 2 ** 32 - 1);

        // This doesn't really matter for this test but it can't be zero
        uint256 currencyRaised = 1;
        MockAuctionWithSweep mockAuction = new MockAuctionWithSweep(currencyRaised, uint64(block.number - 1));
        vm.etch(address(lbp.auction()), address(mockAuction).code);

        vm.deal(address(lbp.auction()), currencyRaised);
        vm.deal(address(lbp), currencyRaised);

        Checkpoint memory checkpoint;
        checkpoint.clearingPrice = clearingPrice;

        // Mock the clearingPrice again after etching
        mockAuctionClearingPrice(lbp, clearingPrice);
        mockCurrencyRaised(lbp, currencyRaised);
        mockAuctionCheckpoint(lbp, checkpoint);

        vm.roll(lbp.migrationBlock());

        vm.expectRevert(abi.encodeWithSelector(TokenPricing.PriceTooHigh.selector, (1 << 192) / clearingPrice));
        lbp.migrate();
    }

    function test_WhenCurrencyIsCurrency1AndClearingPriceIsTooHigh_withToken(
        uint128 totalSupply,
        uint256 clearingPrice,
        uint24 tokenSplit
    ) public {
        // it should revert with PriceTooHigh

        tokenSplit = uint24(bound(tokenSplit, 1, 1e7 - 1));
        uint128 tokenAmount = uint128(uint256(totalSupply) * uint256(tokenSplit) / 1e7);
        vm.assume(tokenAmount > 0 && tokenAmount <= 1e30);

        setupWithSupplyAndTokenSplit(totalSupply, tokenSplit, DAI);
        sendTokensToLBP(address(tokenLauncher), token, lbp, totalSupply);

        // Bound the clearing price to be between type(uint160).max and type(uint256).max
        clearingPrice = bound(clearingPrice, uint256(type(uint160).max) + 1, type(uint256).max);
        // In the case where currency is currency1, the price will not be inverted
        assertEq(lbp.currency() > lbp.token(), true);

        uint256 currencyRaised = FullMath.mulDiv(tokenAmount, clearingPrice, Q192);
        vm.assume(currencyRaised > 0 && currencyRaised <= type(uint128).max);

        MockAuctionWithSweep mockAuction = new MockAuctionWithSweep(currencyRaised, uint64(block.number - 1));
        vm.etch(address(lbp.auction()), address(mockAuction).code);

        deal(DAI, address(lbp.auction()), currencyRaised);
        deal(DAI, address(lbp), currencyRaised);

        Checkpoint memory checkpoint;
        checkpoint.clearingPrice = clearingPrice;

        mockAuctionClearingPrice(lbp, clearingPrice);
        mockCurrencyRaised(lbp, currencyRaised);
        mockAuctionCheckpoint(lbp, checkpoint);

        vm.roll(lbp.migrationBlock());

        vm.expectRevert(abi.encodeWithSelector(TokenPricing.PriceTooHigh.selector, clearingPrice));
        lbp.migrate();
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
        uint256 invertedPrice = InverseHelpers.inverseQ96(veryLowClearingPrice);

        vm.roll(lbp.migrationBlock());

        mockAuctionCheckpoint(
            lbp,
            Checkpoint({
                clearingPrice: veryLowClearingPrice,
                currencyRaisedAtClearingPriceQ96_X7: ValueX7.wrap(0),
                cumulativeMpsPerPrice: 0,
                cumulativeMps: 0,
                prev: 0,
                next: type(uint64).max
            })
        );

        vm.prank(address(lbp.auction()));
        // Expect revert with PriceTooHigh (the error will contain the inverted price)
        vm.expectRevert(abi.encodeWithSelector(TokenPricing.PriceTooHigh.selector, invertedPrice, type(uint160).max));
        lbp.migrate();
    }

    function test_migrate_withETH_revertsWithPriceTooHigh_1() public {
        // This test verifies the handling of prices above MAX_SQRT_PRICE
        sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

        // For ETH, price is inverted, so we need a very LOW clearing price to get a HIGH actual price
        // To get sqrtPrice > MAX_SQRT_PRICE, we need a price that when inverted is very high
        // clearingPrice = (1 << 96)^2 / actualPrice
        // We want actualPrice that results in sqrtPrice > MAX_SQRT_PRICE
        // MAX_SQRT_PRICE is approximately 1461446703485210103287273052203988822378723970342
        // So we need a clearing price close to 0 but not 0
        uint256 veryLowClearingPrice = 1 << 32; // Below the minimum floor price
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
        uint256 invertedPrice = InverseHelpers.inverseQ96(veryLowClearingPrice);

        vm.roll(lbp.migrationBlock());

        mockAuctionCheckpoint(
            lbp,
            Checkpoint({
                clearingPrice: veryLowClearingPrice,
                currencyRaisedAtClearingPriceQ96_X7: ValueX7.wrap(0),
                cumulativeMpsPerPrice: 0,
                cumulativeMps: 0,
                prev: 0,
                next: type(uint64).max
            })
        );

        vm.prank(address(lbp.auction()));
        // Expect revert with PriceTooHigh (the error will contain the inverted price)
        vm.expectRevert(abi.encodeWithSelector(TokenPricing.PriceTooHigh.selector, invertedPrice, type(uint160).max));
        lbp.migrate();
    }

    function test_fuzz_migrate_withNonETHCurrency(uint128 totalSupply, uint24 tokenSplit) public {
        tokenSplit = uint24(bound(tokenSplit, 1, 1e7));

        uint128 tokenAmount = uint128(uint256(totalSupply) * uint256(tokenSplit) / 1e7);
        vm.assume(tokenAmount > 1e7);
        vm.assume(totalSupply.calculateReserveSupply(tokenSplit) <= 1e30);

        setupWithSupplyAndTokenSplit(totalSupply, tokenSplit, DAI);

        // Setup
        sendTokensToLBP(address(tokenLauncher), token, lbp, totalSupply);

        IAuction realAuction = lbp.auction();
        assertFalse(address(realAuction) == address(0));

        // Move to auction start
        vm.roll(realAuction.startBlock());

        // ensure leftover tokens
        uint256 targetPrice = tickNumberToPriceX96(10);

        // Deal DAI and submit bids for alice
        uint128 daiAmount = inputAmountForTokens(tokenAmount, targetPrice);
        deal(DAI, alice, daiAmount);
        vm.prank(alice);
        ERC20(DAI).approve(address(PERMIT2), daiAmount);
        vm.prank(alice);
        IAllowanceTransfer(PERMIT2)
            .approve(DAI, address(realAuction), uint160(daiAmount), uint48(block.timestamp + 1000));

        _submitBidNonEth(realAuction, alice, daiAmount, targetPrice, tickNumberToPriceX96(1), 0);

        vm.roll(realAuction.endBlock());
        realAuction.checkpoint();

        realAuction.sweepCurrency();

        vm.roll(lbp.migrationBlock());

        lbp.migrate();
    }
}
