// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HookTestBase} from "./HookTestBase.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {LaunchHook} from "../../../src/periphery/hooks/LaunchHook.sol";
import {InitializerHook} from "../../../src/periphery/hooks/InitializerHook.sol";
import {IInitializerHook} from "../../../src/interfaces/IInitializerHook.sol";
import {ILaunchHook, LaunchConfig} from "../../../src/interfaces/ILaunchHook.sol";
import {
    MockDynamicFeeModule,
    MockRevertingDynamicFeeModule,
    MockGarbageDynamicFeeModule
} from "test/mocks/MockDynamicFeeModules.sol";

contract LaunchHookNoValidation is LaunchHook {
    constructor(IPoolManager _pm, address _strategy) LaunchHook(_pm, _strategy) {}

    function validateHookAddress(BaseHook) internal pure override {}
}

/// @title LaunchHookTest
/// @notice BTT tests for LaunchHook
///
/// setLaunchConfig
/// ├── when the caller is not authorized
/// │   └── it reverts with NotAuthorized
/// ├── when a config is already registered for the pool
/// │   └── it reverts with LaunchConfigAlreadySet
/// ├── when windowEndBlock < swapStartBlock
/// │   └── it reverts with InvalidWindow
/// ├── when baseFee > MAX_LP_FEE
/// │   └── it reverts with InvalidBaseFee
/// └── when the config is valid
///     ├── it stores the config
///     ├── it marks the pool configured
///     └── it emits LaunchConfigSet
///
/// beforeInitialize
/// ├── when the sender is not authorized
/// │   └── it reverts with InvalidInitializer
/// ├── when the pool fee is not the dynamic fee flag
/// │   └── it reverts with NotDynamicFee
/// ├── when no config is registered for the pool
/// │   └── it reverts with LaunchConfigNotSet
/// ├── when a module is configured
/// │   ├── when the module reverts
/// │   │   └── it reverts with InvalidModule
/// │   ├── when the module returns malformed data
/// │   │   └── it reverts with InvalidModule
/// │   ├── when the module has no code
/// │   │   └── it reverts with InvalidModule
/// │   └── when the module quotes fees
/// │       └── it returns the beforeInitialize selector
/// └── when configured with a dynamic fee pool
///     └── it returns the beforeInitialize selector
///
/// beforeSwap
/// ├── when the block number is before swapStartBlock
/// │   └── it reverts with SwapsNotStarted
/// ├── when the block number is inside the launch window
/// │   ├── when the module is the zero address
/// │   │   └── it returns the base fee with the override flag
/// │   ├── when the module reverts
/// │   │   └── it reverts (fail-closed)
/// │   ├── when the module returns malformed data
/// │   │   └── it reverts (fail-closed)
/// │   ├── when the module fee exceeds MAX_LP_FEE
/// │   │   └── it clamps the fee to MAX_LP_FEE
/// │   └── when the module returns fees
/// │       └── it returns the direction-selected fee with the override flag
/// └── when the block number is at or after windowEndBlock
///     └── it returns the base fee with the override flag without consulting the module
///
/// supportsInterface
/// └── it supports ILaunchHook, IInitializerHook, and IERC165
contract LaunchHookTest is HookTestBase {
    LaunchHook hook;
    MockDynamicFeeModule module;

    function setUp() public {
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG;
        address hookAddr = _computeHookAddress(flags);

        LaunchHookNoValidation impl = new LaunchHookNoValidation(IPoolManager(poolManager), strategy);
        vm.etch(hookAddr, address(impl).code);
        hook = LaunchHook(hookAddr);

        module = new MockDynamicFeeModule();
    }

    function _dynamicFeePoolKey() internal view returns (PoolKey memory key) {
        key = _defaultPoolKey(address(hook));
        key.fee = LPFeeLibrary.DYNAMIC_FEE_FLAG;
    }

    function _config(address _module, uint48 _swapStartBlock, uint48 _windowEndBlock, uint24 _baseFee)
        internal
        pure
        returns (LaunchConfig memory)
    {
        return LaunchConfig({
            swapStartBlock: _swapStartBlock,
            windowEndBlock: _windowEndBlock,
            baseFee: _baseFee,
            tokenIsCurrency0: false,
            module: _module,
            moduleConfig: bytes(""),
            hookConfig: bytes("")
        });
    }

    function _setConfig(PoolKey memory key, LaunchConfig memory config) internal returns (PoolId poolId) {
        poolId = key.toId();
        vm.prank(strategy);
        hook.setLaunchConfig(poolId, config);
    }

    function _swap(PoolKey memory key, bool zeroForOne) internal returns (uint24 fee) {
        SwapParams memory params = SwapParams({zeroForOne: zeroForOne, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});
        vm.prank(poolManager);
        (,, fee) = hook.beforeSwap(address(this), key, params, hex"");
    }

    function test_fuzz_setLaunchConfig_revertsIfNotAuthorized(address caller) public {
        vm.assume(caller != strategy);
        PoolId poolId = _dynamicFeePoolKey().toId();

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(ILaunchHook.NotAuthorized.selector, caller, strategy));
        hook.setLaunchConfig(poolId, _config(address(0), 0, 0, 0));
    }

    function test_setLaunchConfig_revertsIfAlreadySet() public {
        PoolKey memory key = _dynamicFeePoolKey();
        PoolId poolId = _setConfig(key, _config(address(0), 0, 0, 500));

        vm.prank(strategy);
        vm.expectRevert(abi.encodeWithSelector(ILaunchHook.LaunchConfigAlreadySet.selector, poolId));
        hook.setLaunchConfig(poolId, _config(address(0), 0, 0, 500));
    }

    function test_fuzz_setLaunchConfig_revertsIfWindowInvalid(uint48 swapStartBlock, uint48 windowEndBlock) public {
        swapStartBlock = uint48(bound(swapStartBlock, 1, type(uint48).max));
        windowEndBlock = uint48(bound(windowEndBlock, 0, swapStartBlock - 1));
        PoolId poolId = _dynamicFeePoolKey().toId();

        vm.prank(strategy);
        vm.expectRevert(abi.encodeWithSelector(ILaunchHook.InvalidWindow.selector, swapStartBlock, windowEndBlock));
        hook.setLaunchConfig(poolId, _config(address(0), swapStartBlock, windowEndBlock, 0));
    }

    function test_fuzz_setLaunchConfig_revertsIfBaseFeeTooLarge(uint24 baseFee) public {
        baseFee = uint24(bound(baseFee, LPFeeLibrary.MAX_LP_FEE + 1, type(uint24).max));
        PoolId poolId = _dynamicFeePoolKey().toId();

        vm.prank(strategy);
        vm.expectRevert(abi.encodeWithSelector(ILaunchHook.InvalidBaseFee.selector, baseFee));
        hook.setLaunchConfig(poolId, _config(address(0), 0, 0, baseFee));
    }

    function test_fuzz_setLaunchConfig_storesConfigAndEmits(
        address _module,
        uint48 swapStartBlock,
        uint48 windowEndBlock,
        uint24 baseFee,
        bool tokenIsCurrency0,
        bytes memory moduleConfig,
        bytes memory hookConfig
    ) public {
        swapStartBlock = uint48(bound(swapStartBlock, 0, type(uint48).max - 1));
        windowEndBlock = uint48(bound(windowEndBlock, swapStartBlock, type(uint48).max));
        baseFee = uint24(bound(baseFee, 0, LPFeeLibrary.MAX_LP_FEE));

        PoolKey memory key = _dynamicFeePoolKey();
        PoolId poolId = key.toId();
        LaunchConfig memory config = LaunchConfig({
            swapStartBlock: swapStartBlock,
            windowEndBlock: windowEndBlock,
            baseFee: baseFee,
            tokenIsCurrency0: tokenIsCurrency0,
            module: _module,
            moduleConfig: moduleConfig,
            hookConfig: hookConfig
        });

        assertFalse(hook.isConfigured(poolId));

        vm.prank(strategy);
        vm.expectEmit(true, false, false, true, address(hook));
        emit ILaunchHook.LaunchConfigSet(poolId, config);
        hook.setLaunchConfig(poolId, config);

        assertTrue(hook.isConfigured(poolId));
        LaunchConfig memory stored = hook.launchConfig(poolId);
        assertEq(stored.module, _module);
        assertEq(stored.swapStartBlock, swapStartBlock);
        assertEq(stored.windowEndBlock, windowEndBlock);
        assertEq(stored.baseFee, baseFee);
        assertEq(stored.tokenIsCurrency0, tokenIsCurrency0);
        assertEq(stored.moduleConfig, moduleConfig);
        assertEq(stored.hookConfig, hookConfig);
    }

    function test_fuzz_beforeInitialize_revertsIfNotStrategy(address notStrategy) public {
        vm.assume(notStrategy != strategy);
        PoolKey memory key = _dynamicFeePoolKey();

        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(InitializerHook.InvalidInitializer.selector, notStrategy, strategy));
        hook.beforeInitialize(notStrategy, key, 0);
    }

    function test_fuzz_beforeInitialize_revertsIfStaticFee(uint24 fee) public {
        fee = uint24(bound(fee, 0, LPFeeLibrary.MAX_LP_FEE));
        PoolKey memory key = _dynamicFeePoolKey();
        key.fee = fee;
        _setConfig(key, _config(address(0), 0, 0, 500));

        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(ILaunchHook.NotDynamicFee.selector, fee));
        hook.beforeInitialize(strategy, key, 0);
    }

    function test_beforeInitialize_revertsIfNotConfigured() public {
        PoolKey memory key = _dynamicFeePoolKey();

        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(ILaunchHook.LaunchConfigNotSet.selector, key.toId()));
        hook.beforeInitialize(strategy, key, 0);
    }

    function test_beforeInitialize_revertsWhenModuleReverts() public {
        PoolKey memory key = _dynamicFeePoolKey();
        address revertingModule = address(new MockRevertingDynamicFeeModule());
        _setConfig(key, _config(revertingModule, 0, uint48(block.number + 10), 500));

        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(ILaunchHook.InvalidModule.selector, revertingModule));
        hook.beforeInitialize(strategy, key, 0);
    }

    function test_beforeInitialize_revertsWhenModuleReturnsGarbage() public {
        PoolKey memory key = _dynamicFeePoolKey();
        address garbageModule = address(new MockGarbageDynamicFeeModule());
        _setConfig(key, _config(garbageModule, 0, uint48(block.number + 10), 500));

        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(ILaunchHook.InvalidModule.selector, garbageModule));
        hook.beforeInitialize(strategy, key, 0);
    }

    function test_beforeInitialize_revertsWhenModuleHasNoCode() public {
        PoolKey memory key = _dynamicFeePoolKey();
        address eoaModule = makeAddr("eoaModule");
        _setConfig(key, _config(eoaModule, 0, uint48(block.number + 10), 500));

        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(ILaunchHook.InvalidModule.selector, eoaModule));
        hook.beforeInitialize(strategy, key, 0);
    }

    function test_beforeInitialize_succeedsWhenModuleQuotesFees() public {
        PoolKey memory key = _dynamicFeePoolKey();
        _setConfig(key, _config(address(module), 0, uint48(block.number + 10), 500));

        vm.prank(poolManager);
        bytes4 result = hook.beforeInitialize(strategy, key, 0);
        assertEq(result, IHooks.beforeInitialize.selector);
    }

    function test_beforeInitialize_succeedsWhenConfigured() public {
        PoolKey memory key = _dynamicFeePoolKey();
        _setConfig(key, _config(address(0), 0, 0, 500));

        vm.prank(poolManager);
        bytes4 result = hook.beforeInitialize(strategy, key, 0);
        assertEq(result, IHooks.beforeInitialize.selector);
    }

    function test_fuzz_beforeSwap_revertsBeforeSwapStartBlock(uint48 swapStartBlock, uint48 currentBlock) public {
        swapStartBlock = uint48(bound(swapStartBlock, 2, type(uint48).max));
        currentBlock = uint48(bound(currentBlock, 1, swapStartBlock - 1));

        PoolKey memory key = _dynamicFeePoolKey();
        _setConfig(key, _config(address(0), swapStartBlock, swapStartBlock, 500));
        vm.roll(currentBlock);

        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});
        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(ILaunchHook.SwapsNotStarted.selector, swapStartBlock, currentBlock));
        hook.beforeSwap(address(this), key, params, hex"");
    }

    function test_fuzz_beforeSwap_returnsBaseFeeWhenModuleIsZero(uint24 baseFee, bool zeroForOne) public {
        baseFee = uint24(bound(baseFee, 0, LPFeeLibrary.MAX_LP_FEE));
        PoolKey memory key = _dynamicFeePoolKey();
        _setConfig(key, _config(address(0), 0, uint48(block.number + 10), baseFee));

        assertEq(_swap(key, zeroForOne), baseFee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function test_beforeSwap_revertsWhenModuleReverts() public {
        PoolKey memory key = _dynamicFeePoolKey();
        _setConfig(key, _config(address(new MockRevertingDynamicFeeModule()), 0, uint48(block.number + 10), 500));

        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});
        vm.prank(poolManager);
        vm.expectRevert(MockRevertingDynamicFeeModule.ModuleBroken.selector);
        hook.beforeSwap(address(this), key, params, hex"");
    }

    function test_beforeSwap_revertsWhenModuleReturnsGarbage() public {
        PoolKey memory key = _dynamicFeePoolKey();
        _setConfig(key, _config(address(new MockGarbageDynamicFeeModule()), 0, uint48(block.number + 10), 500));

        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});
        vm.prank(poolManager);
        vm.expectRevert();
        hook.beforeSwap(address(this), key, params, hex"");
    }

    function test_fuzz_beforeSwap_clampsModuleFee(uint24 excessFee, bool zeroForOne) public {
        excessFee = uint24(bound(excessFee, LPFeeLibrary.MAX_LP_FEE + 1, type(uint24).max));
        module.setFees(excessFee, excessFee);

        PoolKey memory key = _dynamicFeePoolKey();
        _setConfig(key, _config(address(module), 0, uint48(block.number + 10), 500));

        assertEq(_swap(key, zeroForOne), LPFeeLibrary.MAX_LP_FEE | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function test_fuzz_beforeSwap_selectsFeeByDirection(uint24 zeroForOneFee, uint24 oneForZeroFee) public {
        zeroForOneFee = uint24(bound(zeroForOneFee, 0, LPFeeLibrary.MAX_LP_FEE));
        oneForZeroFee = uint24(bound(oneForZeroFee, 0, LPFeeLibrary.MAX_LP_FEE));
        module.setFees(zeroForOneFee, oneForZeroFee);

        PoolKey memory key = _dynamicFeePoolKey();
        _setConfig(key, _config(address(module), 0, uint48(block.number + 10), 500));

        assertEq(_swap(key, true), zeroForOneFee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
        assertEq(_swap(key, false), oneForZeroFee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function test_fuzz_beforeSwap_returnsBaseFeeAfterWindowWithoutConsultingModule(
        uint48 windowEndBlock,
        uint48 currentBlock,
        bool zeroForOne
    ) public {
        windowEndBlock = uint48(bound(windowEndBlock, 1, type(uint48).max - 1));
        currentBlock = uint48(bound(currentBlock, windowEndBlock, type(uint48).max));

        // A reverting module proves the module is not consulted once the window has ended.
        PoolKey memory key = _dynamicFeePoolKey();
        _setConfig(key, _config(address(new MockRevertingDynamicFeeModule()), 0, windowEndBlock, 500));
        vm.roll(currentBlock);

        assertEq(_swap(key, zeroForOne), 500 | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function test_supportsInterface_supportsLaunchHookInitializerHookAndERC165() public view {
        assertTrue(IERC165(address(hook)).supportsInterface(type(ILaunchHook).interfaceId));
        assertTrue(IERC165(address(hook)).supportsInterface(type(IInitializerHook).interfaceId));
        assertTrue(IERC165(address(hook)).supportsInterface(type(IERC165).interfaceId));
    }
}
