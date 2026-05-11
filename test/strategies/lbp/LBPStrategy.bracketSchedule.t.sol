// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LBPStrategyTestBase} from "./base/LBPStrategyTestBase.sol";
import {ILBPInitializer, LBPInitializationParams} from "src/interfaces/ILBPInitializer.sol";
import {MockLBPInitializer} from "test/mocks/MockLBPInitializer.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {MigratorParams, MigratorParameters, LiquidityAllocationBracket} from "src/libraries/MigratorParams.sol";

/// @notice Tests that verify the bracket schedule controls the LP currency budget.
/// Uses the reference helper _expectedLpCurrencyAmount in the base to assert the contract
/// applies the schedule correctly to whatever currency is raised.
contract LBPStrategy_BracketSchedule_Test is LBPStrategyTestBase {
    function test_zeroRateBracket_consumesNoCurrency(MigrationFuzzParams memory p) public {
        // Single bracket at 0% rate — bracket calc yields 0 LP currency, so the pool should
        // receive nothing and all raised currency should reach fundsRecipient.
        LiquidityAllocationBracket[] memory bp = new LiquidityAllocationBracket[](1);
        bp[0] = LiquidityAllocationBracket({lowerThreshold: 0, rate: 0});

        (MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock, uint128 auctionSupply) =
            _boundMigratorParams(p);
        p.currencyRaised = bound(p.currencyRaised, 1, uint256(uint128(type(int128).max)));
        p.initialPriceX96 = _boundInitialPriceX96(p.initialPriceX96);
        p.tokensSold = uint128(bound(p.tokensSold, 1, auctionSupply));

        (MockLBPInitializer initializer, MockERC20 token) = _initializeWith(mp, totalSupply, endBlock, bp);
        initializer.setLbpInitializationParams(
            LBPInitializationParams({
                initialPriceX96: p.initialPriceX96, tokensSold: p.tokensSold, currencyRaised: p.currencyRaised
            })
        );
        vm.deal(address(initializer), p.currencyRaised);
        token.transfer(address(initializer), totalSupply);
        vm.roll(mp.migrationBlock);

        uint256 fundsBefore = fundsRecipient.balance;
        uint256 poolBefore = address(POOL_MANAGER).balance;

        strategy.migrate(ILBPInitializer(address(initializer)));

        // Pool receives no currency — bracket calc was 0
        assertEq(address(POOL_MANAGER).balance, poolBefore);
        // All raised currency reaches fundsRecipient
        assertEq(fundsRecipient.balance - fundsBefore, p.currencyRaised);
        assertEq(address(strategy).balance, 0);
    }

    function test_fuzz_poolNeverConsumesMoreThanBracketBudget(MigrationFuzzParams memory p) public {
        // The bracket calc produces an upper bound on what the LP can consume; the planner
        // may consume less if positions can't absorb the full budget (e.g., out-of-range).
        LiquidityAllocationBracket[] memory brackets = _boundBrackets(p.bpParams);
        (MockLBPInitializer initializer,) = _setupForMigration(p);
        uint256 currencyRaised = initializer.lbpInitializationParams().currencyRaised;

        uint256 expectedLpBudget = _expectedLpCurrencyAmount(currencyRaised, brackets);

        uint256 fundsBefore = fundsRecipient.balance;
        uint256 poolBefore = address(POOL_MANAGER).balance;
        strategy.migrate(ILBPInitializer(address(initializer)));
        uint256 poolDelta = address(POOL_MANAGER).balance - poolBefore;
        uint256 fundsDelta = fundsRecipient.balance - fundsBefore;

        // Pool consumption is capped by the bracket-determined LP budget
        assertLe(poolDelta, expectedLpBudget);
        // Conservation: fee=0 by default, so every wei reaches the pool or fundsRecipient
        assertEq(poolDelta + fundsDelta, currencyRaised);
        assertEq(address(strategy).balance, 0);
    }

    function test_fuzz_singleFullRateBracket_poolConsumesAtMostRaised(MigrationFuzzParams memory p) public {
        // Single bracket at 100% rate — the entire raised amount is the LP budget.
        // The planner can consume up to currencyRaised; leftover (if any) is swept.
        LiquidityAllocationBracket[] memory bp = new LiquidityAllocationBracket[](1);
        bp[0] = LiquidityAllocationBracket({lowerThreshold: 0, rate: MigratorParams.MAX_BRACKET_RATE});

        (MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock, uint128 auctionSupply) =
            _boundMigratorParams(p);
        p.currencyRaised = _boundCurrencyRaised(p.currencyRaised, bp);
        p.initialPriceX96 = _boundInitialPriceX96(p.initialPriceX96);
        p.tokensSold = uint128(bound(p.tokensSold, 1, auctionSupply));

        (MockLBPInitializer initializer, MockERC20 token) = _initializeWith(mp, totalSupply, endBlock, bp);
        initializer.setLbpInitializationParams(
            LBPInitializationParams({
                initialPriceX96: p.initialPriceX96, tokensSold: p.tokensSold, currencyRaised: p.currencyRaised
            })
        );
        vm.deal(address(initializer), p.currencyRaised);
        token.transfer(address(initializer), totalSupply);
        vm.roll(mp.migrationBlock);

        uint256 fundsBefore = fundsRecipient.balance;
        uint256 poolBefore = address(POOL_MANAGER).balance;

        strategy.migrate(ILBPInitializer(address(initializer)));

        uint256 poolDelta = address(POOL_MANAGER).balance - poolBefore;
        uint256 fundsDelta = fundsRecipient.balance - fundsBefore;

        // Pool consumes at most the full raised amount (100% bracket budget)
        assertLe(poolDelta, p.currencyRaised);
        // Conservation
        assertEq(poolDelta + fundsDelta, p.currencyRaised);
        assertEq(address(strategy).balance, 0);
    }
}
