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

    function test_fuzz_afterInitialize_setsInitializedBlock(uint128 blockNumber, uint160 sqrtPriceX96, int24 tick)
        public
    {
        vm.assume(blockNumber > 0);
        PoolKey memory key = _defaultPoolKey(address(hook));

        vm.roll(blockNumber);
        vm.prank(poolManager);
        hook.afterInitialize(strategy, key, sqrtPriceX96, tick);

        assertEq(hook.initializedBlock(), blockNumber);
    }

    function test_fuzz_beforeRemoveLiquidity_revertsBeforeUnlock(
        uint128 initBlock,
        uint128 removeBlock,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta,
        bytes32 salt,
        address sender
    ) public {
        initBlock = uint128(bound(initBlock, 1, type(uint128).max - TIMELOCK_DURATION));
        removeBlock = uint128(bound(removeBlock, initBlock, initBlock + TIMELOCK_DURATION - 1));

        PoolKey memory key = _defaultPoolKey(address(hook));

        vm.roll(initBlock);
        vm.prank(poolManager);
        hook.afterInitialize(strategy, key, 0, 0);

        vm.roll(removeBlock);
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: liquidityDelta, salt: salt
        });

        uint256 unlockBlock = uint256(initBlock) + TIMELOCK_DURATION;
        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(TimelockHook.Timelocked.selector, unlockBlock, removeBlock));
        hook.beforeRemoveLiquidity(sender, key, params, hex"");
    }

    function test_fuzz_beforeRemoveLiquidity_succeedsAfterUnlock(
        uint128 initBlock,
        uint128 blocksAfterUnlock,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta,
        bytes32 salt,
        address sender
    ) public {
        vm.assume(initBlock > 0);
        uint256 unlockBlock = uint256(initBlock) + TIMELOCK_DURATION;
        vm.assume(unlockBlock + blocksAfterUnlock <= type(uint128).max);
        uint256 removeBlock = unlockBlock + blocksAfterUnlock;

        PoolKey memory key = _defaultPoolKey(address(hook));

        vm.roll(initBlock);
        vm.prank(poolManager);
        hook.afterInitialize(strategy, key, 0, 0);

        vm.roll(removeBlock);
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: liquidityDelta, salt: salt
        });

        vm.prank(poolManager);
        bytes4 result = hook.beforeRemoveLiquidity(sender, key, params, hex"");
        assertEq(result, IHooks.beforeRemoveLiquidity.selector);
    }
}
