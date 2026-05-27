// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LBPStrategyTestBase} from "./base/LBPStrategyTestBase.sol";
import {ILBPInitializer} from "src/interfaces/ILBPInitializer.sol";
import {MockLBPInitializer} from "test/mocks/MockLBPInitializer.sol";
import {MigratorParams, LiquidityAllocationBracket} from "src/libraries/MigratorParams.sol";

/// @notice Tests that verify the bracket schedule controls the LP currency budget.
/// Uses the reference helper _expectedLpCurrencyAmount in the base to assert the contract
/// applies the schedule correctly to whatever currency is raised.
contract LBPStrategy_BracketSchedule_Test is LBPStrategyTestBase {
    function test_zeroRateBracket_consumesNoCurrency(MigrationFuzzParams memory p) public {
        // Single bracket at 0% rate — bracket calc yields 0 LP currency, so the pool should
        // receive nothing and all raised currency should reach recipient.
        LiquidityAllocationBracket[] memory bp = new LiquidityAllocationBracket[](1);
        bp[0] = LiquidityAllocationBracket({lowerThreshold: 0, rate: 0});

        p.currencyRaised = bound(p.currencyRaised, 1, uint256(uint128(type(int128).max)));
        (MockLBPInitializer initializer,) = _setupForMigrationWithSchedule(p, bp, p.currencyRaised);

        uint256 fundsBefore = recipient.balance;
        uint256 poolBefore = address(POOL_MANAGER).balance;

        strategy.migrate(ILBPInitializer(address(initializer)));

        // Pool receives no currency — bracket calc was 0
        assertEq(address(POOL_MANAGER).balance, poolBefore);
        // All raised currency reaches recipient
        assertEq(recipient.balance - fundsBefore, p.currencyRaised);
        assertEq(address(strategy).balance, 0);
    }

    function test_fuzz_poolNeverConsumesMoreThanBracketBudget(MigrationFuzzParams memory p) public {
        // The bracket calc produces an upper bound on what the LP can consume; the planner
        // may consume less if positions can't absorb the full budget (e.g., out-of-range).
        LiquidityAllocationBracket[] memory brackets = _boundBrackets(p.bpParams);
        (MockLBPInitializer initializer,) = _setupForMigration(p);
        uint256 currencyRaised = initializer.lbpInitializationParams().currencyRaised;

        uint256 expectedLpBudget = _expectedLpCurrencyAmount(currencyRaised, brackets);

        uint256 fundsBefore = recipient.balance;
        uint256 poolBefore = address(POOL_MANAGER).balance;
        strategy.migrate(ILBPInitializer(address(initializer)));
        uint256 poolDelta = address(POOL_MANAGER).balance - poolBefore;
        uint256 fundsDelta = recipient.balance - fundsBefore;

        // Pool consumption is capped by the bracket-determined LP budget
        assertLe(poolDelta, expectedLpBudget);
        // No protocol fee is configured, so all raised currency is either deposited into the pool or swept.
        assertEq(poolDelta + fundsDelta, currencyRaised);
        assertEq(address(strategy).balance, 0);
    }

    function test_fuzz_singleFullRateBracket_poolConsumesAtMostRaised(MigrationFuzzParams memory p) public {
        // Single bracket at 100% rate — the entire raised amount is the LP budget.
        // The planner can consume up to currencyRaised; leftover (if any) is swept.
        LiquidityAllocationBracket[] memory bp = new LiquidityAllocationBracket[](1);
        bp[0] = LiquidityAllocationBracket({lowerThreshold: 0, rate: MigratorParams.MAX_BRACKET_RATE});

        p.currencyRaised = _boundCurrencyRaised(p.currencyRaised, bp);
        (MockLBPInitializer initializer,) = _setupForMigrationWithSchedule(p, bp, p.currencyRaised);

        uint256 fundsBefore = recipient.balance;
        uint256 poolBefore = address(POOL_MANAGER).balance;

        strategy.migrate(ILBPInitializer(address(initializer)));

        uint256 poolDelta = address(POOL_MANAGER).balance - poolBefore;
        uint256 fundsDelta = recipient.balance - fundsBefore;

        // Pool consumes at most the full raised amount (100% bracket budget)
        assertLe(poolDelta, p.currencyRaised);
        assertEq(poolDelta + fundsDelta, p.currencyRaised);
        assertEq(address(strategy).balance, 0);
    }

    function test_twoBracketSchedule_poolCannotConsumeMoreThanTieredBudget(MigrationFuzzParams memory p) public {
        uint24 rate0 = uint24(bound(p.bpParams.rate0, 1, MigratorParams.MAX_BRACKET_RATE));
        uint24 rate1 = uint24(bound(p.bpParams.rate1, 1, MigratorParams.MAX_BRACKET_RATE));
        uint128 threshold1 = uint128(bound(uint256(p.bpParams.threshold0), 1, type(uint128).max));
        uint256 currencyRaised = bound(p.currencyRaised, 1, type(uint256).max);

        LiquidityAllocationBracket[] memory bp = new LiquidityAllocationBracket[](2);
        bp[0] = LiquidityAllocationBracket({lowerThreshold: 0, rate: rate0});
        bp[1] = LiquidityAllocationBracket({lowerThreshold: threshold1, rate: rate1});

        (MockLBPInitializer initializer,) = _setupForMigrationWithSchedule(p, bp, currencyRaised);
        uint256 expectedLpBudget = _expectedLpCurrencyAmount(currencyRaised, bp);

        uint256 fundsBefore = recipient.balance;
        uint256 poolBefore = address(POOL_MANAGER).balance;

        strategy.migrate(ILBPInitializer(address(initializer)));

        uint256 currencyToPool = address(POOL_MANAGER).balance - poolBefore;
        uint256 currencyToFundsRecipient = recipient.balance - fundsBefore;

        assertLe(currencyToPool, expectedLpBudget);
        assertEq(currencyToPool + currencyToFundsRecipient, currencyRaised);
        assertEq(address(strategy).balance, 0);
    }

    function test_threeBracketSchedule_poolCannotConsumeMoreThanTieredBudget(MigrationFuzzParams memory p) public {
        uint24 rate0 = uint24(bound(p.bpParams.rate0, 1, MigratorParams.MAX_BRACKET_RATE));
        uint24 rate1 = uint24(bound(p.bpParams.rate1, 1, MigratorParams.MAX_BRACKET_RATE));
        uint24 rate2 = uint24(bound(p.bpParams.rate2, 0, MigratorParams.MAX_BRACKET_RATE));
        uint128 threshold1 = uint128(bound(uint256(p.bpParams.threshold0), 1, type(uint128).max - 1));
        uint128 threshold2 = uint128(bound(uint256(p.bpParams.threshold1), threshold1 + 1, type(uint128).max));
        uint256 currencyRaised = bound(p.currencyRaised, 1, type(uint256).max);

        LiquidityAllocationBracket[] memory bp = new LiquidityAllocationBracket[](3);
        bp[0] = LiquidityAllocationBracket({lowerThreshold: 0, rate: rate0});
        bp[1] = LiquidityAllocationBracket({lowerThreshold: threshold1, rate: rate1});
        bp[2] = LiquidityAllocationBracket({lowerThreshold: threshold2, rate: rate2});

        (MockLBPInitializer initializer,) = _setupForMigrationWithSchedule(p, bp, currencyRaised);
        uint256 expectedLpBudget = _expectedLpCurrencyAmount(currencyRaised, bp);

        uint256 fundsBefore = recipient.balance;
        uint256 poolBefore = address(POOL_MANAGER).balance;

        strategy.migrate(ILBPInitializer(address(initializer)));

        uint256 currencyToPool = address(POOL_MANAGER).balance - poolBefore;
        uint256 currencyToFundsRecipient = recipient.balance - fundsBefore;

        assertLe(currencyToPool, expectedLpBudget);
        assertEq(currencyToPool + currencyToFundsRecipient, currencyRaised);
        assertEq(address(strategy).balance, 0);
    }

    function test_currencyAboveUint128Max_flowsIntoLastBracket(MigrationFuzzParams memory p, uint256 _tail) public {
        // because lowerThreshold is uint128, any cumulative currency above type(uint128).max is necessarily allocated at the last
        // bracket's rate.

        // Setup: bracket 0 has 0% rate (its uint128.max chunk contributes nothing to the LP budget,
        // so the entire chunk MUST be swept). Bracket 1 has 100% rate, so the tail (currency above
        // uint128.max) is the LP budget — exactly `tail`.
        LiquidityAllocationBracket[] memory bp = new LiquidityAllocationBracket[](2);
        bp[0] = LiquidityAllocationBracket({lowerThreshold: 0, rate: 0});
        bp[1] = LiquidityAllocationBracket({
            lowerThreshold: type(uint128).max, rate: uint24(MigratorParams.MAX_BRACKET_RATE)
        });

        // Fuzz the tail (amount above uint128.max). Cap at uint256.max - uint128.max so
        // currencyRaised doesn't overflow uint256.
        uint256 tail = bound(_tail, 1, type(uint256).max - uint256(type(uint128).max));
        uint256 currencyRaised = uint256(type(uint128).max) + tail;

        // LP budget is exactly `tail` — bracket 0 contributes 0, bracket 1 takes the tail at 100%.
        assertEq(_expectedLpCurrencyAmount(currencyRaised, bp), tail);

        (MockLBPInitializer initializer,) = _setupForMigrationWithSchedule(p, bp, currencyRaised);

        uint256 fundsBefore = recipient.balance;
        uint256 poolBefore = address(POOL_MANAGER).balance;

        strategy.migrate(ILBPInitializer(address(initializer)));

        uint256 currencyToPool = address(POOL_MANAGER).balance - poolBefore;
        uint256 currencyToFundsRecipient = recipient.balance - fundsBefore;

        // The entire bracket-0 chunk (uint128.max) is guaranteed swept since rate0 == 0.
        assertGe(currencyToFundsRecipient, uint256(type(uint128).max));
        // Pool consumption capped by the LP budget AND v4's int128 delta limit.
        uint256 cap = tail < uint128(type(int128).max) ? tail : uint128(type(int128).max);
        assertLe(currencyToPool, cap);
        assertEq(currencyToPool + currencyToFundsRecipient, currencyRaised);
        assertEq(address(strategy).balance, 0);
    }
}
