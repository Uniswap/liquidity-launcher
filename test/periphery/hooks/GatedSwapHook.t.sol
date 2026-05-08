// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HookTestBase} from "./HookTestBase.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {GatedSwapHook} from "src/periphery/hooks/GatedSwapHook.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";

contract GatedSwapHookNoValidation is GatedSwapHook {
    constructor(IPoolManager _pm, address _gatekeeper) GatedSwapHook(_pm, _gatekeeper) {}

    function validateHookAddress(BaseHook) internal pure override {}
}

contract GatedSwapHookTest is HookTestBase {
    GatedSwapHook hook;
    address gatekeeper = makeAddr("gatekeeper");

    function setUp() public {
        uint160 flags = Hooks.BEFORE_SWAP_FLAG;
        address hookAddr = _computeHookAddress(flags);

        GatedSwapHookNoValidation impl = new GatedSwapHookNoValidation(IPoolManager(poolManager), gatekeeper);
        vm.etch(hookAddr, address(impl).code);
        hook = GatedSwapHook(hookAddr);
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
        vm.expectRevert(abi.encodeWithSelector(GatedSwapHook.SwapsNotApproved.selector));
        hook.beforeSwap(sender, key, params, hex"");
    }

    function test_fuzz_approveSwaps_revertsIfNotGatekeeper(address caller) public {
        vm.assume(caller != gatekeeper);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(GatedSwapHook.NotGatekeeper.selector, caller, gatekeeper));
        hook.approveSwaps();
    }

    function test_approveSwaps_succeedsForGatekeeper() public {
        assertFalse(hook.isApproved());
        vm.prank(gatekeeper);
        hook.approveSwaps();
        assertTrue(hook.isApproved());
    }

    function test_fuzz_beforeSwap_succeedsAfterApproval(
        address sender,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96
    ) public {
        vm.prank(gatekeeper);
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
