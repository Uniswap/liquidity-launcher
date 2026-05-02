// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {AdvancedLBPStrategyTestBase} from "./base/AdvancedLBPStrategyTestBase.sol";
import {ILBPStrategyBase} from "src/interfaces/ILBPStrategyBase.sol";

contract AdvancedLBPStrategySweepTest is AdvancedLBPStrategyTestBase {
    event TokensSwept(address indexed operator, uint256 amount);
    event CurrencySwept(address indexed operator, uint256 amount);

    function test_sweepToken_revertsWithMigrationNotComplete() public {
        // migration has not been called; migratedBlock == 0
        vm.roll(lbp.sweepBlock());
        vm.expectRevert(ILBPStrategyBase.MigrationNotComplete.selector);
        vm.prank(migratorParams.operator);
        lbp.sweepToken();
    }

    function test_sweepToken_revertsWithSweepNotAllowed() public {
        // migration guard fires before sweep-block guard; MigrationNotComplete is the first revert
        vm.expectRevert(ILBPStrategyBase.MigrationNotComplete.selector);
        vm.prank(migratorParams.operator);
        lbp.sweepToken();
    }

    function test_sweepToken_revertsWithNotOperator() public {
        // migration guard fires before operator guard; MigrationNotComplete is the first revert
        vm.roll(lbp.sweepBlock());
        vm.expectRevert(ILBPStrategyBase.MigrationNotComplete.selector);
        vm.prank(address(liquidityLauncher));
        lbp.sweepToken();
    }

    function test_sweepToken_succeeds() public {
        sendTokensToLBP(address(liquidityLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);
        assertEq(token.balanceOf(address(lbp)), DEFAULT_TOTAL_SUPPLY / 2);
        assertEq(Currency.wrap(lbp.token()).balanceOf(address(lbp)), lbp.reserveTokenAmount());
        assertEq(Currency.wrap(lbp.token()).balanceOf(lbp.operator()), 0);
        // Simulate migration having occurred by writing migratedBlock via stdstore
        stdstore.target(address(lbp)).sig("migratedBlock()").checked_write(uint256(lbp.migrationBlock()));
        vm.roll(lbp.sweepBlock());
        vm.expectEmit(true, true, true, true);
        emit TokensSwept(lbp.operator(), lbp.reserveTokenAmount());
        vm.prank(lbp.operator());
        lbp.sweepToken();
        assertEq(Currency.wrap(lbp.token()).balanceOf(address(lbp)), 0);
        assertEq(Currency.wrap(lbp.token()).balanceOf(lbp.operator()), lbp.reserveTokenAmount());
    }

    function test_sweepCurrency_revertsWithMigrationNotComplete() public {
        // migration has not been called; migratedBlock == 0
        vm.roll(lbp.sweepBlock());
        vm.expectRevert(ILBPStrategyBase.MigrationNotComplete.selector);
        vm.prank(migratorParams.operator);
        lbp.sweepCurrency();
    }

    function test_sweepCurrency_revertsWithSweepNotAllowed() public {
        // migration guard fires before sweep-block guard; MigrationNotComplete is the first revert
        vm.expectRevert(ILBPStrategyBase.MigrationNotComplete.selector);
        vm.prank(migratorParams.operator);
        lbp.sweepCurrency();
    }

    function test_sweepCurrency_revertsWithNotOperator() public {
        // migration guard fires before operator guard; MigrationNotComplete is the first revert
        vm.roll(lbp.sweepBlock());
        vm.expectRevert(ILBPStrategyBase.MigrationNotComplete.selector);
        vm.prank(address(liquidityLauncher));
        lbp.sweepCurrency();
    }

    function test_sweepCurrency_succeeds() public {
        vm.deal(address(lbp), 1 ether); // give LBP some ETH
        assertEq(Currency.wrap(address(0)).balanceOf(address(lbp)), 1 ether);
        assertEq(Currency.wrap(address(0)).balanceOf(lbp.operator()), 0);
        // Simulate migration having occurred by writing migratedBlock via stdstore
        stdstore.target(address(lbp)).sig("migratedBlock()").checked_write(uint256(lbp.migrationBlock()));
        vm.roll(lbp.sweepBlock());
        vm.expectEmit(true, true, true, true);
        emit CurrencySwept(lbp.operator(), 1 ether);
        vm.prank(lbp.operator());
        lbp.sweepCurrency();
        assertEq(Currency.wrap(address(0)).balanceOf(address(lbp)), 0);
        assertEq(Currency.wrap(address(0)).balanceOf(lbp.operator()), 1 ether);
    }
}
