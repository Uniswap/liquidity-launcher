// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HookTestBase} from "./HookTestBase.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {FrontrunningProtectionHook} from "src/periphery/hooks/FrontrunningProtectionHook.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {LBPHookBase} from "src/periphery/hooks/LBPHookBase.sol";

contract FrontrunningProtectionHookNoValidation is FrontrunningProtectionHook {
    constructor(IPoolManager _pm, address _strategy) FrontrunningProtectionHook(_pm, _strategy) {}

    function validateHookAddress(BaseHook) internal pure override {}
}

contract FrontrunningProtectionHookTest is HookTestBase {
    FrontrunningProtectionHook hook;

    function setUp() public {
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG;
        address hookAddr = _computeHookAddress(flags);

        FrontrunningProtectionHookNoValidation impl =
            new FrontrunningProtectionHookNoValidation(IPoolManager(poolManager), strategy);
        vm.etch(hookAddr, address(impl).code);
        hook = FrontrunningProtectionHook(hookAddr);
    }

    function test_fuzz_beforeInitialize_revertsIfNotStrategy(address notStrategy, uint160 sqrtPriceX96) public {
        vm.assume(notStrategy != strategy);
        PoolKey memory key = _defaultPoolKey(address(hook));

        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(LBPHookBase.InvalidInitializer.selector, notStrategy, strategy));
        hook.beforeInitialize(notStrategy, key, sqrtPriceX96);
    }

    function test_fuzz_beforeInitialize_succeedsForStrategy(uint160 sqrtPriceX96) public {
        PoolKey memory key = _defaultPoolKey(address(hook));

        vm.prank(poolManager);
        bytes4 result = hook.beforeInitialize(strategy, key, sqrtPriceX96);
        assertEq(result, IHooks.beforeInitialize.selector);
    }
}
