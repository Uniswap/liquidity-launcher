// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HookTestBase} from "./HookTestBase.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SelfInitializerHook} from "src/periphery/hooks/SelfInitializerHook.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";

contract SelfInitializerHookNoValidation is SelfInitializerHook {
    constructor(IPoolManager _pm, address _strategy) SelfInitializerHook(_pm, _strategy) {}

    function validateHookAddress(BaseHook) internal pure override {}
}

contract SelfInitializerHookTest is HookTestBase {
    SelfInitializerHook hook;

    function setUp() public {
        address hookAddr = _computeHookAddress(Hooks.BEFORE_INITIALIZE_FLAG);

        SelfInitializerHookNoValidation impl = new SelfInitializerHookNoValidation(IPoolManager(poolManager), strategy);
        vm.etch(hookAddr, address(impl).code);
        hook = SelfInitializerHook(hookAddr);
    }

    function test_fuzz_beforeInitialize_revertsIfNotStrategy(address notStrategy) public {
        vm.assume(notStrategy != strategy);
        PoolKey memory key = _defaultPoolKey(address(hook));

        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(SelfInitializerHook.InvalidInitializer.selector, notStrategy, strategy));
        hook.beforeInitialize(notStrategy, key, 0);
    }

    function test_beforeInitialize_succeedsForStrategy() public {
        PoolKey memory key = _defaultPoolKey(address(hook));

        vm.prank(poolManager);
        bytes4 result = hook.beforeInitialize(strategy, key, 0);
        assertEq(result, IHooks.beforeInitialize.selector);
    }
}
