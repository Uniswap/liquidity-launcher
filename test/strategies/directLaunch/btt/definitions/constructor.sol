// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DirectLaunchTestBase} from "../../base/DirectLaunchTestBase.sol";
import {DirectLaunchStrategy} from "../../../../../src/strategies/DirectLaunchStrategy.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";

/// @title ConstructorTest
/// @notice BTT tests for DirectLaunchStrategy.constructor
///
/// constructor
/// ├── when a required address is zero
/// │   └── it reverts with ZeroAddress
/// ├── when the initial tick is not aligned
/// │   └── it reverts with InvalidTickRange
/// ├── when the initial tick exceeds the maximum usable tick
/// │   └── it reverts with InvalidTickRange
/// ├── when the initial tick does not exceed the minimum usable tick
/// │   └── it reverts with InvalidTickRange
/// ├── when the supply does not fit in a single position
/// │   └── it reverts with UnrealizableLaunch
/// └── when the configuration is valid
///     ├── it stores the immutable configuration
///     └── it derives a position liquidity that fits in a single position
contract ConstructorTest is DirectLaunchTestBase {
    function test_fuzz_WhenRequiredAddressIsZero(uint8 zeroIndex) public {
        zeroIndex = uint8(bound(zeroIndex, 0, 2));

        vm.expectRevert(DirectLaunchStrategy.ZeroAddress.selector);
        new DirectLaunchStrategy(
            zeroIndex == 0 ? address(0) : launcher,
            zeroIndex == 1 ? IPositionManager(address(0)) : IPositionManager(address(positionManager)),
            zeroIndex == 2 ? IPoolManager(address(0)) : poolManager,
            INITIAL_TICK
        );
    }

    function test_fuzz_WhenInitialTickIsNotAligned(int24 initialTick) public {
        initialTick = int24(bound(initialTick, LOWEST_REALIZABLE_TICK, TickMath.maxUsableTick(strategy.TICK_SPACING())));
        vm.assume(initialTick % strategy.TICK_SPACING() != 0);

        vm.expectRevert(DirectLaunchStrategy.InvalidTickRange.selector);
        _deployStrategy(initialTick);
    }

    function test_WhenInitialTickExceedsMaximumUsableTick() public {
        int24 tickSpacing = strategy.TICK_SPACING();
        vm.expectRevert(DirectLaunchStrategy.InvalidTickRange.selector);
        _deployStrategy(TickMath.maxUsableTick(tickSpacing) + tickSpacing);
    }

    function test_WhenInitialTickEqualsMinimumUsableTick() public {
        int24 minUsable = TickMath.minUsableTick(strategy.TICK_SPACING());
        vm.expectRevert(DirectLaunchStrategy.InvalidTickRange.selector);
        _deployStrategy(minUsable);
    }

    function test_fuzz_WhenInitialTickIsBelowMinimumUsableTick(int24 initialTick) public {
        int24 tickSpacing = strategy.TICK_SPACING();
        // Aligned ticks at or below the min usable tick, so the floor check is what reverts rather than alignment.
        initialTick = int24(
            bound(initialTick, type(int24).min / tickSpacing, TickMath.minUsableTick(tickSpacing) / tickSpacing)
        ) * tickSpacing;

        vm.expectRevert(DirectLaunchStrategy.InvalidTickRange.selector);
        _deployStrategy(initialTick);
    }

    function test_WhenSupplyDoesNotFitInSinglePosition() public {
        int24 tickSpacing = strategy.TICK_SPACING();
        vm.expectRevert(DirectLaunchStrategy.UnrealizableLaunch.selector);
        _deployStrategy(LOWEST_REALIZABLE_TICK - tickSpacing);
    }

    function test_fuzz_WhenSupplyDoesNotFitInSinglePosition(int24 initialTick) public {
        int24 tickSpacing = strategy.TICK_SPACING();
        // Aligned ticks between the min usable tick (exclusive) and the realizability boundary (exclusive):
        // deep enough that the full supply's liquidity exceeds maxLiquidityPerTick.
        initialTick = int24(
            bound(
                initialTick,
                TickMath.minUsableTick(tickSpacing) / tickSpacing + 1,
                (LOWEST_REALIZABLE_TICK - tickSpacing) / tickSpacing
            )
        ) * tickSpacing;

        vm.expectRevert(DirectLaunchStrategy.UnrealizableLaunch.selector);
        _deployStrategy(initialTick);
    }

    function test_WhenInitialTickIsLowestRealizableTick_deploys() public {
        DirectLaunchStrategy deployed = _deployStrategy(LOWEST_REALIZABLE_TICK);
        assertEq(deployed.initialTick(), LOWEST_REALIZABLE_TICK);
    }

    function test_WhenInitialTickIsMaximumUsableTick_deploys() public {
        int24 maxUsable = TickMath.maxUsableTick(strategy.TICK_SPACING());
        DirectLaunchStrategy deployed = _deployStrategy(maxUsable);
        assertEq(deployed.initialTick(), maxUsable);
    }

    function test_WhenConfigurationIsValid_storesConfiguration() public view {
        assertEq(strategy.launcher(), launcher);
        assertEq(address(strategy.positionManager()), address(positionManager));
        assertEq(address(strategy.poolManager()), address(poolManager));
        assertEq(strategy.initialTick(), INITIAL_TICK);
        assertEq(strategy.initialSqrtPriceX96(), TickMath.getSqrtPriceAtTick(INITIAL_TICK));
        assertGt(strategy.positionLiquidity(), 0);
    }

    function test_fuzz_WhenConfigurationIsValid_positionLiquidityFitsInSinglePosition(int24 initialTick) public {
        int24 tickSpacing = strategy.TICK_SPACING();
        initialTick = int24(
            bound(initialTick, LOWEST_REALIZABLE_TICK / tickSpacing, TickMath.maxUsableTick(tickSpacing) / tickSpacing)
        ) * tickSpacing;

        DirectLaunchStrategy deployed = _deployStrategy(initialTick);
        assertGt(deployed.positionLiquidity(), 0);
        assertLe(deployed.positionLiquidity(), Pool.tickSpacingToMaxLiquidityPerTick(tickSpacing));
    }
}
