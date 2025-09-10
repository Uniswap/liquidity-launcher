// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LBPStrategyBasicTestBase} from "./base/LBPStrategyBasicTestBase.sol";
import {ILBPStrategyBasic} from "../../src/interfaces/ILBPStrategyBasic.sol";

contract LBPStrategyBasicSweepTest is LBPStrategyBasicTestBase {
    event TokensSwept(address indexed operator);

    function test_sweep_revertsWithSweepNotAllowed() public {
        vm.expectRevert(
            abi.encodeWithSelector(ILBPStrategyBasic.SweepNotAllowed.selector, lbp.sweepBlock(), block.number)
        );
        vm.prank(migratorParams.operator);
        lbp.sweep();
    }

    function test_sweep_revertsWithNotOperator() public {
        vm.roll(lbp.sweepBlock());
        vm.expectRevert(
            abi.encodeWithSelector(ILBPStrategyBasic.NotOperator.selector, address(tokenLauncher), lbp.operator())
        );
        vm.prank(address(tokenLauncher));
        lbp.sweep();
    }

    function test_sweep_succeeds() public {
        sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);
        assertEq(token.balanceOf(address(lbp)), DEFAULT_TOTAL_SUPPLY / 2);
        assertEq(Currency.wrap(lbp.token()).balanceOf(address(lbp)), lbp.reserveSupply());
        assertEq(Currency.wrap(lbp.token()).balanceOf(lbp.operator()), 0);
        vm.roll(lbp.sweepBlock());
        vm.prank(lbp.operator());
        vm.expectEmit(true, true, true, true);
        emit TokensSwept(lbp.operator());
        lbp.sweep();
        assertEq(Currency.wrap(lbp.token()).balanceOf(address(lbp)), 0);
        assertEq(Currency.wrap(lbp.token()).balanceOf(lbp.operator()), lbp.reserveSupply());
    }
}
