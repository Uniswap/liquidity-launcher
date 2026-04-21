// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HookTestBase} from "./HookTestBase.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TimelockHook} from "src/periphery/hooks/TimelockHook.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {LBPHookBase} from "src/periphery/hooks/LBPHookBase.sol";

contract TimelockHookNoValidation is TimelockHook {
    constructor(IPoolManager _pm, address _strategy, uint256 _duration) TimelockHook(_pm, _strategy, _duration) {}

    function validateHookAddress(BaseHook) internal pure override {}
}

contract TimelockHookTest is HookTestBase {
    TimelockHook hook;
    uint256 constant TIMELOCK_DURATION = 100;

    function setUp() public {
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG;
        address hookAddr = _computeHookAddress(flags);

        TimelockHookNoValidation impl =
            new TimelockHookNoValidation(IPoolManager(poolManager), strategy, TIMELOCK_DURATION);
        vm.etch(hookAddr, address(impl).code);
        hook = TimelockHook(hookAddr);
    }

    function test_afterInitialize_setsInitializedBlock() public {
        PoolKey memory key = _defaultPoolKey(address(hook));

        vm.roll(50);
        vm.prank(poolManager);
        hook.afterInitialize(strategy, key, 0, 0);

        assertEq(hook.initializedBlock(), 50);
    }

    function test_beforeRemoveLiquidity_revertsBeforeUnlock() public {
        PoolKey memory key = _defaultPoolKey(address(hook));

        // Initialize at block 50
        vm.roll(50);
        vm.prank(poolManager);
        hook.afterInitialize(strategy, key, 0, 0);

        // Try to remove at block 100 (unlock is at 150)
        vm.roll(100);
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: -100, tickUpper: 100, liquidityDelta: -1e18, salt: bytes32(0)});

        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(TimelockHook.Timelocked.selector, 150, 100));
        hook.beforeRemoveLiquidity(address(this), key, params, hex"");
    }

    function test_beforeRemoveLiquidity_succeedsAfterUnlock() public {
        PoolKey memory key = _defaultPoolKey(address(hook));

        // Initialize at block 50
        vm.roll(50);
        vm.prank(poolManager);
        hook.afterInitialize(strategy, key, 0, 0);

        // Remove at block 150 (unlock block)
        vm.roll(150);
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: -100, tickUpper: 100, liquidityDelta: -1e18, salt: bytes32(0)});

        vm.prank(poolManager);
        bytes4 result = hook.beforeRemoveLiquidity(address(this), key, params, hex"");
        assertEq(result, IHooks.beforeRemoveLiquidity.selector);
    }
}
