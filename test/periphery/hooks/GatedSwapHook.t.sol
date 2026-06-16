// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HookTestBase} from "./HookTestBase.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {GatedSwapHook} from "src/periphery/hooks/GatedSwapHook.sol";
import {InitializerHook} from "src/periphery/hooks/InitializerHook.sol";
import {IInitializerHook} from "src/interfaces/IInitializerHook.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

contract GatedSwapHookNoValidation is GatedSwapHook {
    constructor(IPoolManager _pm, address _strategy, address _gatekeeper) GatedSwapHook(_pm, _strategy, _gatekeeper) {}

    function validateHookAddress(BaseHook) internal pure override {}
}

contract GatedSwapHookTest is HookTestBase {
    GatedSwapHook hook;
    address gatekeeper = makeAddr("gatekeeper");

    function setUp() public {
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG;
        address hookAddr = _computeHookAddress(flags);

        GatedSwapHookNoValidation impl = new GatedSwapHookNoValidation(IPoolManager(poolManager), strategy, gatekeeper);
        vm.etch(hookAddr, address(impl).code);
        hook = GatedSwapHook(hookAddr);
    }

    function test_fuzz_beforeInitialize_revertsIfNotStrategy(address notStrategy) public {
        vm.assume(notStrategy != strategy);
        PoolKey memory key = _defaultPoolKey(address(hook));

        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(InitializerHook.InvalidInitializer.selector, notStrategy, strategy));
        hook.beforeInitialize(notStrategy, key, 0);
    }

    function test_beforeInitialize_succeedsForStrategy() public {
        PoolKey memory key = _defaultPoolKey(address(hook));

        vm.prank(poolManager);
        bytes4 result = hook.beforeInitialize(strategy, key, 0);
        assertEq(result, IHooks.beforeInitialize.selector);
    }

    function test_supportsInterface_supportsInitializerHookAndERC165() public view {
        assertTrue(IERC165(address(hook)).supportsInterface(type(IInitializerHook).interfaceId));
        assertTrue(IERC165(address(hook)).supportsInterface(type(IERC165).interfaceId));
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
