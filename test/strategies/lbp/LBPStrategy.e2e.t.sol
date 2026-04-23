// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LBPStrategyTestBase} from "./base/LBPStrategyTestBase.sol";
import {ILBPStrategy} from "src/interfaces/ILBPStrategy.sol";
import {ILBPInitializer, LBPInitializationParams} from "src/interfaces/ILBPInitializer.sol";
import {MockLBPInitializer} from "test/mocks/MockLBPInitializer.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";

/// @notice End-to-end fuzz tests exercising the full initializeDistribution → migrate flow
contract LBPStrategy_E2E_Test is LBPStrategyTestBase {
    function test_fuzz_initAndMigrate_happyPath(
        uint24 split,
        int24 tickSpacing,
        uint24 fee,
        uint128 currencyRaised,
        uint128 tokensSold
    ) public {
        // Bound to valid ranges
        split = uint24(bound(split, 1, 1e7));
        tickSpacing = int24(bound(tickSpacing, TickMath.MIN_TICK_SPACING, TickMath.MAX_TICK_SPACING));
        fee = uint24(bound(fee, 0, LPFeeLibrary.MAX_LP_FEE));
        // Ensure currencyRaised * split / 1e7 > 0 to avoid NoCurrencyRaised
        currencyRaised = uint128(bound(currencyRaised, 1e7 / split + 1, type(uint128).max));
        tokensSold =
            uint128(bound(tokensSold, 1, DEFAULT_TOTAL_SUPPLY - DEFAULT_SUPPLY_FOR_LP - DEFAULT_CUSTODY_TOKENS));

        // Build params
        ILBPStrategy.MigratorParameters memory mp = _defaultMigratorParams();
        mp.currencySplitForLP = split;
        mp.poolTickSpacing = tickSpacing;
        mp.poolLPFee = fee;

        // Initialize
        factory.setCustodyTokens(mp.supplyForLP + mp.custodyTokens);
        strategy.initializeDistribution(address(token), DEFAULT_TOTAL_SUPPLY, _encodeConfigData(mp, hex""), bytes32(0));
        MockLBPInitializer initializer = factory.deployedInitializer();

        // Verify migration params were stored (migrationBlock is a non-zero sentinel)
        (uint64 storedMigrationBlock,,,,,,,,,) = strategy.initializers(ILBPInitializer(address(initializer)));
        assertEq(storedMigrationBlock, mp.migrationBlock);

        // Fund the initializer
        initializer.setLbpInitializationParams(
            LBPInitializationParams({
                initialPriceX96: FixedPoint96.Q96, tokensSold: tokensSold, currencyRaised: currencyRaised
            })
        );
        vm.deal(address(initializer), currencyRaised);
        token.transfer(address(initializer), DEFAULT_SUPPLY_FOR_LP + DEFAULT_CUSTODY_TOKENS);

        // Advance to migration block
        vm.roll(mp.migrationBlock);

        // Mock v4 calls
        vm.mockCall(poolManager, abi.encodeWithSelector(IPoolManager.initialize.selector), abi.encode(int24(0)));
        vm.mockCall(positionManager, abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector), "");

        // Record balances before migration
        uint256 recipientBalBefore = fundsRecipient.balance;
        uint256 recipientTokenBalBefore = token.balanceOf(fundsRecipient);

        // Migrate
        strategy.migrate(ILBPInitializer(address(initializer)));

        // Strategy should be empty after migration
        assertEq(token.balanceOf(address(strategy)), 0);
        assertEq(address(strategy).balance, 0);

        // fundsRecipient should have received something
        assertTrue(
            fundsRecipient.balance > recipientBalBefore || token.balanceOf(fundsRecipient) > recipientTokenBalBefore
        );
    }

    function test_fuzz_twoAuctionsIsolated(uint64 migrationOffset1, uint64 migrationOffset2) public {
        migrationOffset1 = uint64(bound(migrationOffset1, 200, 500));
        migrationOffset2 = uint64(bound(migrationOffset2, 501, 1000));

        // First auction
        ILBPStrategy.MigratorParameters memory mp1 = _defaultMigratorParams();
        mp1.migrationBlock = uint64(block.number) + migrationOffset1;
        factory.setCustodyTokens(mp1.supplyForLP + mp1.custodyTokens);
        strategy.initializeDistribution(address(token), DEFAULT_TOTAL_SUPPLY, _encodeConfigData(mp1, hex""), bytes32(0));
        MockLBPInitializer init1 = factory.deployedInitializer();

        // Second auction with different params
        ILBPStrategy.MigratorParameters memory mp2 = _defaultMigratorParams();
        mp2.migrationBlock = uint64(block.number) + migrationOffset2;
        factory.setCustodyTokens(mp2.supplyForLP + mp2.custodyTokens);
        strategy.initializeDistribution(address(token), DEFAULT_TOTAL_SUPPLY, _encodeConfigData(mp2, hex""), bytes32(0));
        MockLBPInitializer init2 = factory.deployedInitializer();

        // Each initializer has its own stored migration params
        (uint64 stored1,,,,,,,,,) = strategy.initializers(ILBPInitializer(address(init1)));
        (uint64 stored2,,,,,,,,,) = strategy.initializers(ILBPInitializer(address(init2)));
        assertEq(stored1, mp1.migrationBlock);
        assertEq(stored2, mp2.migrationBlock);
        assertTrue(stored1 != stored2);
    }

    function test_fuzz_currencySplitAppliedCorrectly(uint24 split, uint128 currencyRaised, uint128 tokensSold) public {
        split = uint24(bound(split, 1, 1e7));
        // Ensure currencyRaised * split / 1e7 > 0 to avoid NoCurrencyRaised
        currencyRaised = uint128(bound(currencyRaised, 1e7 / split + 1, type(uint128).max));
        tokensSold =
            uint128(bound(tokensSold, 1, DEFAULT_TOTAL_SUPPLY - DEFAULT_SUPPLY_FOR_LP - DEFAULT_CUSTODY_TOKENS));

        ILBPStrategy.MigratorParameters memory mp = _defaultMigratorParams();
        mp.currencySplitForLP = split;

        factory.setCustodyTokens(mp.supplyForLP + mp.custodyTokens);
        strategy.initializeDistribution(address(token), DEFAULT_TOTAL_SUPPLY, _encodeConfigData(mp, hex""), bytes32(0));
        MockLBPInitializer initializer = factory.deployedInitializer();

        initializer.setLbpInitializationParams(
            LBPInitializationParams({
                initialPriceX96: FixedPoint96.Q96, tokensSold: tokensSold, currencyRaised: currencyRaised
            })
        );
        vm.deal(address(initializer), currencyRaised);
        token.transfer(address(initializer), DEFAULT_SUPPLY_FOR_LP + DEFAULT_CUSTODY_TOKENS);

        vm.roll(mp.migrationBlock);
        vm.mockCall(poolManager, abi.encodeWithSelector(IPoolManager.initialize.selector), abi.encode(int24(0)));
        vm.mockCall(positionManager, abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector), "");

        uint256 recipientBalBefore = fundsRecipient.balance;
        uint256 pmBalBefore = positionManager.balance;
        strategy.migrate(ILBPInitializer(address(initializer)));

        // With PositionPlanner wired in, some currency may be forwarded to the (mocked) position manager
        // when `_transferAssetsAndExecutePlan` sends value alongside `modifyLiquidities`. Any amount not
        // consumed by the LP is swept to fundsRecipient. The sum of both must equal the total raised.
        uint256 receivedByFunds = fundsRecipient.balance - recipientBalBefore;
        uint256 receivedByPM = positionManager.balance - pmBalBefore;
        assertEq(receivedByFunds + receivedByPM, currencyRaised);
        // Strategy should retain nothing after the migration sweep.
        assertEq(address(strategy).balance, 0);
    }
}
