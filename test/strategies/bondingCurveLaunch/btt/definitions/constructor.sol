// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BondingCurveLaunchTestBase} from "../../base/BondingCurveLaunchTestBase.sol";
import {BondingCurveLaunchStrategy} from "../../../../../src/strategies/BondingCurveLaunchStrategy.sol";
import {IBondingCurveLaunchHook} from "../../../../../src/interfaces/IBondingCurveLaunchHook.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @title ConstructorTest
/// @notice BTT tests for BondingCurveLaunchStrategy.constructor
///
/// constructor
/// ├── when a required address is zero
/// │   └── it reverts with ZeroAddress
/// ├── when either tick is not aligned
/// │   └── it reverts with InvalidTickRange
/// ├── when the terminal tick is outside the usable range
/// │   └── it reverts with InvalidTickRange
/// ├── when the initial tick exceeds the usable range
/// │   └── it reverts with InvalidTickRange
/// ├── when the terminal tick does not precede the initial tick
/// │   └── it reverts with InvalidTickRange
/// └── when the configuration is valid
///     ├── it stores the immutable configuration
///     └── it derives a supply split that sums to the fixed supply
contract ConstructorTest is BondingCurveLaunchTestBase {
    function test_fuzz_WhenRequiredAddressIsZero(uint8 zeroIndex) public {
        zeroIndex = uint8(bound(zeroIndex, 0, 4));

        vm.expectRevert(BondingCurveLaunchStrategy.ZeroAddress.selector);
        new BondingCurveLaunchStrategy(
            zeroIndex == 0 ? address(0) : launcher,
            zeroIndex == 1 ? IPositionManager(address(0)) : IPositionManager(address(positionManager)),
            zeroIndex == 2 ? IPoolManager(address(0)) : poolManager,
            zeroIndex == 3 ? IBondingCurveLaunchHook(address(0)) : launchHook,
            zeroIndex == 4 ? address(0) : dynamicFeeModule,
            INITIAL_TICK,
            GRADUATION_TICK
        );
    }

    function test_fuzz_WhenTickIsNotAligned(int24 tick, bool useInitialTick) public {
        tick = int24(bound(tick, GRADUATION_TICK + 1, INITIAL_TICK - 1));
        vm.assume(tick % strategy.TICK_SPACING() != 0);

        vm.expectRevert(BondingCurveLaunchStrategy.InvalidTickRange.selector);
        _deployStrategy(useInitialTick ? tick : INITIAL_TICK, useInitialTick ? GRADUATION_TICK : tick);
    }

    function test_WhenGraduationTickIsMinimumUsableTick() public {
        int24 tickSpacing = strategy.TICK_SPACING();
        vm.expectRevert(BondingCurveLaunchStrategy.InvalidTickRange.selector);
        _deployStrategy(INITIAL_TICK, TickMath.minUsableTick(tickSpacing));
    }

    function test_WhenGraduationTickIsBelowMinimumUsableTick() public {
        int24 tickSpacing = strategy.TICK_SPACING();
        vm.expectRevert(BondingCurveLaunchStrategy.InvalidTickRange.selector);
        _deployStrategy(INITIAL_TICK, TickMath.minUsableTick(tickSpacing) - tickSpacing);
    }

    function test_WhenInitialTickExceedsMaximumUsableTick() public {
        int24 tickSpacing = strategy.TICK_SPACING();
        vm.expectRevert(BondingCurveLaunchStrategy.InvalidTickRange.selector);
        _deployStrategy(TickMath.maxUsableTick(tickSpacing) + tickSpacing, GRADUATION_TICK);
    }

    function test_WhenGraduationTickEqualsInitialTick() public {
        vm.expectRevert(BondingCurveLaunchStrategy.InvalidTickRange.selector);
        _deployStrategy(INITIAL_TICK, INITIAL_TICK);
    }

    function test_WhenGraduationTickExceedsInitialTick() public {
        int24 tickSpacing = strategy.TICK_SPACING();
        vm.expectRevert(BondingCurveLaunchStrategy.InvalidTickRange.selector);
        _deployStrategy(INITIAL_TICK, INITIAL_TICK + tickSpacing);
    }

    function test_WhenConfigurationIsValid_storesConfigurationAndDerivesSupplySplit() public view {
        assertEq(strategy.launcher(), launcher);
        assertEq(address(strategy.launchHook()), address(launchHook));
        assertEq(strategy.dynamicFeeModule(), dynamicFeeModule);
        assertEq(address(strategy.positionManager()), address(positionManager));
        assertEq(address(strategy.poolManager()), address(poolManager));
        assertEq(strategy.initialTick(), INITIAL_TICK);
        assertEq(strategy.graduationTick(), GRADUATION_TICK);
        assertEq(strategy.initialSqrtPriceX96(), TickMath.getSqrtPriceAtTick(INITIAL_TICK));
        assertEq(strategy.graduationSqrtPriceX96(), TickMath.getSqrtPriceAtTick(GRADUATION_TICK));
        assertEq(strategy.curveSupply() + strategy.reserveSupply(), TOTAL_SUPPLY);
        assertApproxEqRel(strategy.curveSupply(), TOTAL_SUPPLY * 80 / 100, 6e15);
    }
}
