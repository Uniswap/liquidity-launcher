// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CanonicalLaunchTestBase} from "../../base/CanonicalLaunchTestBase.sol";
import {CanonicalLaunchStrategy} from "../../../../../src/strategies/CanonicalLaunchStrategy.sol";
import {DirectLaunchStrategy} from "../../../../../src/strategies/DirectLaunchStrategy.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @title ConstructorTest
/// @notice BTT tests for CanonicalLaunchStrategy.constructor
///
/// constructor
/// ├── when a required address is zero
/// │   └── it reverts with ZeroAddress
/// ├── when the initial tick is not aligned
/// │   └── it reverts with InvalidInitialTick
/// ├── when the initial tick is at or below the minimum usable tick
/// │   └── it reverts with InvalidInitialTick
/// ├── when the initial tick exceeds the maximum usable tick
/// │   └── it reverts with InvalidInitialTick
/// └── when the configuration is valid
///     └── it stores the immutable configuration
contract ConstructorTest is CanonicalLaunchTestBase {
    function test_fuzz_WhenRequiredAddressIsZero(uint8 zeroIndex) public {
        zeroIndex = uint8(bound(zeroIndex, 0, 3));
        address configuredLauncher = zeroIndex == 0 ? address(0) : launcher;
        DirectLaunchStrategy configuredDirectLaunchStrategy = zeroIndex == 1
            ? DirectLaunchStrategy(payable(address(0)))
            : DirectLaunchStrategy(payable(address(directLaunchStrategy)));
        address configuredLaunchHook = zeroIndex == 2 ? address(0) : launchHook;
        address configuredModule = zeroIndex == 3 ? address(0) : dynamicFeeModule;

        vm.expectRevert(CanonicalLaunchStrategy.ZeroAddress.selector);
        new CanonicalLaunchStrategy(
            configuredLauncher, configuredDirectLaunchStrategy, configuredLaunchHook, configuredModule, INITIAL_TICK
        );
    }

    function test_fuzz_WhenInitialTickIsNotAligned(int24 initialTick) public {
        initialTick = int24(
            bound(
                initialTick,
                TickMath.minUsableTick(strategy.TICK_SPACING()) + 1,
                TickMath.maxUsableTick(strategy.TICK_SPACING())
            )
        );
        vm.assume(initialTick % strategy.TICK_SPACING() != 0);

        vm.expectRevert(CanonicalLaunchStrategy.InvalidInitialTick.selector);
        _deployStrategy(initialTick);
    }

    function test_WhenInitialTickIsMinimumUsableTick() public {
        int24 initialTick = TickMath.minUsableTick(strategy.TICK_SPACING());
        vm.expectRevert(CanonicalLaunchStrategy.InvalidInitialTick.selector);
        _deployStrategy(initialTick);
    }

    function test_WhenInitialTickIsBelowMinimumUsableTick() public {
        int24 initialTick = TickMath.minUsableTick(strategy.TICK_SPACING()) - strategy.TICK_SPACING();
        vm.expectRevert(CanonicalLaunchStrategy.InvalidInitialTick.selector);
        _deployStrategy(initialTick);
    }

    function test_WhenInitialTickExceedsMaximumUsableTick() public {
        int24 initialTick = TickMath.maxUsableTick(strategy.TICK_SPACING()) + strategy.TICK_SPACING();
        vm.expectRevert(CanonicalLaunchStrategy.InvalidInitialTick.selector);
        _deployStrategy(initialTick);
    }

    function test_WhenConfigurationIsValid_storesImmutableConfiguration() public view {
        assertEq(strategy.launcher(), launcher);
        assertEq(address(strategy.directLaunchStrategy()), address(directLaunchStrategy));
        assertEq(strategy.launchHook(), launchHook);
        assertEq(strategy.dynamicFeeModule(), dynamicFeeModule);
        assertEq(address(strategy.positionManager()), address(positionManager));
        assertEq(strategy.initialTick(), INITIAL_TICK);
        assertEq(strategy.initialSqrtPriceX96(), TickMath.getSqrtPriceAtTick(INITIAL_TICK));
    }
}
