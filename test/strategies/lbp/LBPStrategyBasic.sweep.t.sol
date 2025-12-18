// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LBPStrategyBasicTestBase} from "./base/LBPStrategyBasicTestBase.sol";
import {ILBPStrategyBase} from "src/interfaces/ILBPStrategyBase.sol";

contract LBPStrategyBasicSweepTest is LBPStrategyBasicTestBase {
    event TokensSwept(address indexed operator, uint256 amount);
    event CurrencySwept(address indexed operator, uint256 amount);

    function test_sweepToken_revertsWithSweepNotAllowed() public {
        vm.expectRevert(
            abi.encodeWithSelector(ILBPStrategyBase.SweepNotAllowed.selector, lbp.sweepBlock(), block.number)
        );
        vm.prank(migratorParams.operator);
        lbp.sweepToken();
    }

    function test_sweepToken_revertsWithNotOperator() public {
        vm.roll(lbp.sweepBlock());
        vm.expectRevert(
            abi.encodeWithSelector(ILBPStrategyBase.NotOperator.selector, address(liquidityLauncher), lbp.operator())
        );
        vm.prank(address(liquidityLauncher));
        lbp.sweepToken();
    }

    function test_sweepToken_succeeds() public {
        sendTokensToLBP(address(liquidityLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);
        assertEq(token.balanceOf(address(lbp)), DEFAULT_TOTAL_SUPPLY / 2);
        assertEq(Currency.wrap(lbp.token()).balanceOf(address(lbp)), lbp.reserveSupply());
        assertEq(Currency.wrap(lbp.token()).balanceOf(lbp.operator()), 0);
        vm.roll(lbp.sweepBlock());
        vm.expectEmit(true, true, true, true);
        emit TokensSwept(lbp.operator(), lbp.reserveSupply());
        vm.prank(lbp.operator());
        lbp.sweepToken();
        assertEq(Currency.wrap(lbp.token()).balanceOf(address(lbp)), 0);
        assertEq(Currency.wrap(lbp.token()).balanceOf(lbp.operator()), lbp.reserveSupply());
    }

    function test_sweepCurrency_revertsWithSweepNotAllowed() public {
        vm.expectRevert(
            abi.encodeWithSelector(ILBPStrategyBase.SweepNotAllowed.selector, lbp.sweepBlock(), block.number)
        );
        vm.prank(migratorParams.operator);
        lbp.sweepCurrency();
    }

    function test_sweepCurrency_revertsWithNotOperator() public {
        vm.roll(lbp.sweepBlock());
        vm.expectRevert(
            abi.encodeWithSelector(ILBPStrategyBase.NotOperator.selector, address(liquidityLauncher), lbp.operator())
        );
        vm.prank(address(liquidityLauncher));
        lbp.sweepCurrency();
    }

    function test_sweepCurrency_succeeds() public {
        vm.deal(address(lbp), 1 ether); // give LBP some ETH
        assertEq(Currency.wrap(address(0)).balanceOf(address(lbp)), 1 ether);
        assertEq(Currency.wrap(address(0)).balanceOf(lbp.operator()), 0);
        vm.roll(lbp.sweepBlock());
        vm.expectEmit(true, true, true, true);
        emit CurrencySwept(lbp.operator(), 1 ether);
        vm.prank(lbp.operator());
        lbp.sweepCurrency();
        assertEq(Currency.wrap(address(0)).balanceOf(address(lbp)), 0);
        assertEq(Currency.wrap(address(0)).balanceOf(lbp.operator()), 1 ether);
    }
}
