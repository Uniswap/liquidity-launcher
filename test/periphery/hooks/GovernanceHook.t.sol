// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HookTestBase} from "./HookTestBase.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {GovernanceHook} from "src/periphery/hooks/GovernanceHook.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";

contract GovernanceHookNoValidation is GovernanceHook {
    constructor(IPoolManager _pm, address _governance) GovernanceHook(_pm, _governance) {}

    function validateHookAddress(BaseHook) internal pure override {}
}

contract GovernanceHookTest is HookTestBase {
    GovernanceHook hook;
    address governance = makeAddr("governance");

    function setUp() public {
        uint160 flags = Hooks.BEFORE_SWAP_FLAG;
        address hookAddr = _computeHookAddress(flags);

        GovernanceHookNoValidation impl = new GovernanceHookNoValidation(IPoolManager(poolManager), governance);
        vm.etch(hookAddr, address(impl).code);
        hook = GovernanceHook(hookAddr);
    }

    function test_fuzz_beforeSwap_revertsIfNotApproved(
        address sender,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96
    ) public {
        PoolKey memory key = _defaultPoolKey(address(hook));
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: sqrtPriceLimitX96
        });

        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(GovernanceHook.SwapsNotApproved.selector));
        hook.beforeSwap(sender, key, params, hex"");
    }

    function test_fuzz_approveSwaps_revertsIfNotGovernance(address caller) public {
        vm.assume(caller != governance);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(GovernanceHook.NotGovernance.selector, caller, governance));
        hook.approveSwaps();
    }

    function test_approveSwaps_succeedsForGovernance() public {
        assertFalse(hook.isApproved());
        vm.prank(governance);
        hook.approveSwaps();
        assertTrue(hook.isApproved());
    }

    function test_fuzz_beforeSwap_succeedsAfterApproval(
        address sender,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96
    ) public {
        vm.prank(governance);
        hook.approveSwaps();

        PoolKey memory key = _defaultPoolKey(address(hook));
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: sqrtPriceLimitX96
        });

        vm.prank(poolManager);
        (bytes4 result,,) = hook.beforeSwap(sender, key, params, hex"");
        assertEq(result, IHooks.beforeSwap.selector);
    }
}
