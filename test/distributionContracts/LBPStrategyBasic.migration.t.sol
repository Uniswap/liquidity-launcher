// SPDX-License-Identifier: UNLICENSED
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
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

contract LBPStrategyBasicMigrationTest is LBPStrategyBasicTestBase {
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
        vm.expectRevert(abi.encodeWithSelector(Pool.PoolAlreadyInitialized.selector));
        lbp.migrate();
    }

    function test_migrate_revertsWithInvalidSqrtPrice() public {
        // Send tokens but don't set initial price
        sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

        vm.roll(lbp.migrationBlock());
        vm.prank(address(tokenLauncher));
        vm.expectRevert(abi.encodeWithSelector(TickMath.InvalidSqrtPrice.selector, 0));
        lbp.migrate();
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
            WETH9,
            address(3)
        );

        // Migrate
        // (Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, IHooks hooks) = lbp.key();
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: lbp.poolLPFee(),
            tickSpacing: lbp.poolTickSpacing(),
            hooks: IHooks(address(lbp))
        });
        vm.expectEmit(true, false, false, true);
        emit Migrated(poolKey, TickMath.getSqrtPriceAtTick(0));
        migrateToMigrationBlock(lbp);

        // Take balance snapshot after
        BalanceSnapshot memory afterMigration =
            takeBalanceSnapshot(address(token), address(0), POSITION_MANAGER, POOL_MANAGER, WETH9, address(3));

        // Verify pool initialization
        assertEq(lbp.initialSqrtPriceX96(), TickMath.getSqrtPriceAtTick(0));
        assertEq(lbp.initialTokenAmount(), tokenAmount);
        assertEq(lbp.initialCurrencyAmount(), ethAmount);

        // Verify position
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
        assertLBPStateAfterMigration(lbp, address(token), address(0), WETH9);
        assertBalancesAfterMigration(before, afterMigration, false);
    }

    function test_migrate_fullRange_withNonETHCurrency_succeeds() public {
        // Setup with DAI
        setupWithCurrency(DAI);

        uint128 tokenAmount = DEFAULT_TOTAL_SUPPLY / 2;
        uint128 daiAmount = DEFAULT_TOTAL_SUPPLY / 2;

        // Setup for migration
        sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

        // Give auction DAI
        deal(DAI, address(lbp.auction()), daiAmount);

        onNotifyToken(lbp, DAI, tokenAmount, daiAmount);

        // Take balance snapshot
        BalanceSnapshot memory before =
            takeBalanceSnapshot(address(token), DAI, POSITION_MANAGER, POOL_MANAGER, WETH9, address(3));

        // Migrate
        migrateToMigrationBlock(lbp);

        // Take balance snapshot after
        BalanceSnapshot memory afterMigration =
            takeBalanceSnapshot(address(token), DAI, POSITION_MANAGER, POOL_MANAGER, WETH9, address(3));

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
        assertLBPStateAfterMigration(lbp, address(token), DAI, WETH9);
        assertBalancesAfterMigration(before, afterMigration, false);
    }

    // ============ One-Sided Position Migration Tests ============

    function test_migrate_withOneSidedPosition_withETH_succeeds() public {
        uint128 ethAmount = 500e18;
        uint128 tokenAmount = lbp.reserveSupply() / 2; // 250e18

        // Setup
        sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);
        onNotifyETH(lbp, tokenAmount, ethAmount);

        // Take balance snapshot
        BalanceSnapshot memory before =
            takeBalanceSnapshot(address(token), address(0), POSITION_MANAGER, POOL_MANAGER, WETH9, address(3));

        // Migrate
        migrateToMigrationBlock(lbp);

        // Take balance snapshot after
        BalanceSnapshot memory afterMigration =
            takeBalanceSnapshot(address(token), address(0), POSITION_MANAGER, POOL_MANAGER, WETH9, address(3));

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

        // Verify one-sided position
        assertPositionCreated(
            IPositionManager(POSITION_MANAGER),
            nextTokenId + 1,
            address(0),
            address(token),
            500, // poolLPFee
            1, // poolTickSpacing
            TickMath.MIN_TICK,
            TickMath.getTickAtSqrtPrice(lbp.initialSqrtPriceX96())
        );

        // Verify balances
        assertLBPStateAfterMigration(lbp, address(token), address(0), WETH9);
        assertBalancesAfterMigration(before, afterMigration, true);
    }

    function test_migrate_withOneSidedPosition_withNonETHCurrency_succeeds() public {
        // Setup with DAI and larger tick spacing
        migratorParams = createMigratorParams(DAI, 500, 20, DEFAULT_TOKEN_SPLIT, address(3));
        _deployLBPStrategy(DEFAULT_TOTAL_SUPPLY);

        uint128 daiAmount = DEFAULT_TOTAL_SUPPLY / 2;
        uint128 tokenAmount = lbp.reserveSupply() / 2;

        // Setup for migration
        sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

        // Calculate price (DAI/token)
        deal(DAI, address(lbp.auction()), daiAmount);
        vm.prank(address(lbp.auction()));
        ERC20(DAI).approve(address(lbp), daiAmount);

        uint256 priceX192 = FullMath.mulDiv(daiAmount, 2 ** 192, tokenAmount);

        vm.prank(address(lbp.auction()));
        lbp.onNotify(abi.encode(priceX192, tokenAmount, daiAmount));

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
        assertLBPStateAfterMigration(lbp, address(token), DAI, WETH9);
    }

    // ============ Helper Functions ============

    function _setupForMigration(uint128 tokenAmount, uint128 currencyAmount) private {
        sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);
        onNotifyETH(lbp, tokenAmount, currencyAmount);
    }
}
