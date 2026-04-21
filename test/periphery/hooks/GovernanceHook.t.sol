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
import {LBPHookBase} from "src/periphery/hooks/LBPHookBase.sol";

contract GovernanceHookNoValidation is GovernanceHook {
    constructor(IPoolManager _pm, address _strategy, address _governance) GovernanceHook(_pm, _strategy, _governance) {}

    function validateHookAddress(BaseHook) internal pure override {}
}

contract GovernanceHookTest is HookTestBase {
    GovernanceHook hook;
    address governance = makeAddr("governance");

    function setUp() public {
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG;
        address hookAddr = _computeHookAddress(flags);

        GovernanceHookNoValidation impl =
            new GovernanceHookNoValidation(IPoolManager(poolManager), strategy, governance);
        vm.etch(hookAddr, address(impl).code);
        hook = GovernanceHook(hookAddr);
    }

    function test_beforeInitialize_revertsIfNotStrategy() public {
        address notStrategy = makeAddr("notStrategy");
        PoolKey memory key = _defaultPoolKey(address(hook));

        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(LBPHookBase.InvalidInitializer.selector, notStrategy, strategy));
        hook.beforeInitialize(notStrategy, key, 0);
    }

    function test_beforeInitialize_succeedsForStrategy() public {
        PoolKey memory key = _defaultPoolKey(address(hook));

        vm.prank(poolManager);
        bytes4 result = hook.beforeInitialize(strategy, key, 0);
        assertEq(result, IHooks.beforeInitialize.selector);
    }

    function test_beforeSwap_revertsIfNotApproved() public {
        PoolKey memory key = _defaultPoolKey(address(hook));
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: 1e18, sqrtPriceLimitX96: 0});

        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(GovernanceHook.SwapsNotApproved.selector, address(this)));
        hook.beforeSwap(address(this), key, params, hex"");
    }

    function test_approveSwaps_revertsIfNotGovernance() public {
        vm.expectRevert(abi.encodeWithSelector(GovernanceHook.NotGovernance.selector, address(this), governance));
        hook.approveSwaps();
    }

    function test_approveSwaps_succeedsForGovernance() public {
        vm.prank(governance);
        hook.approveSwaps();
        assertTrue(hook.isApproved());
    }

    function test_beforeSwap_succeedsAfterApproval() public {
        vm.prank(governance);
        hook.approveSwaps();

        PoolKey memory key = _defaultPoolKey(address(hook));
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: 1e18, sqrtPriceLimitX96: 0});

        vm.prank(poolManager);
        (bytes4 result,,) = hook.beforeSwap(address(this), key, params, hex"");
        assertEq(result, IHooks.beforeSwap.selector);
    }
}
