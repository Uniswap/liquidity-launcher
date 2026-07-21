// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BondingCurveLaunchTestBase} from "../../base/BondingCurveLaunchTestBase.sol";
import {BondingCurveLaunchStrategy} from "../../../../../src/strategies/BondingCurveLaunchStrategy.sol";
import {IBondingCurveLaunchHook} from "../../../../../src/interfaces/IBondingCurveLaunchHook.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";

/// @title ConstructorTest
/// @notice BTT tests for BondingCurveLaunchStrategy.constructor
///
/// constructor
/// ├── when a required address is zero
/// │   └── it reverts with ZeroAddress
/// ├── when either tick is not aligned
/// │   └── it reverts with InvalidTickRange
/// ├── when the terminal tick is negative
/// │   └── it reverts with InvalidTickRange
/// ├── when the initial tick exceeds the usable range
/// │   └── it reverts with InvalidTickRange
/// ├── when the terminal tick does not precede the initial tick
/// │   └── it reverts with InvalidTickRange
/// └── when the configuration is valid
///     ├── it stores the immutable configuration
///     ├── it derives a supply split that sums to the fixed supply
///     └── it derives a curve liquidity that fits in a single position
contract ConstructorTest is BondingCurveLaunchTestBase {
    function test_fuzz_WhenRequiredAddressIsZero(uint8 zeroIndex) public {
        zeroIndex = uint8(bound(zeroIndex, 0, 3));

        vm.expectRevert(BondingCurveLaunchStrategy.ZeroAddress.selector);
        new BondingCurveLaunchStrategy(
            zeroIndex == 0 ? address(0) : launcher,
            zeroIndex == 1 ? IPositionManager(address(0)) : IPositionManager(address(positionManager)),
            zeroIndex == 2 ? IPoolManager(address(0)) : poolManager,
            zeroIndex == 3 ? IBondingCurveLaunchHook(address(0)) : launchHook,
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

    function test_WhenGraduationTickIsNegative() public {
        int24 tickSpacing = strategy.TICK_SPACING();
        vm.expectRevert(BondingCurveLaunchStrategy.InvalidTickRange.selector);
        _deployStrategy(INITIAL_TICK, -tickSpacing);
    }

    function test_fuzz_WhenGraduationTickIsNegative(int24 graduationTick) public {
        int24 tickSpacing = strategy.TICK_SPACING();
        // Aligned negative ticks only, so the floor check is what reverts rather than alignment.
        graduationTick =
            int24(bound(graduationTick, TickMath.minUsableTick(tickSpacing) / tickSpacing, -1)) * tickSpacing;

        vm.expectRevert(BondingCurveLaunchStrategy.InvalidTickRange.selector);
        _deployStrategy(INITIAL_TICK, graduationTick);
    }

    function test_WhenGraduationTickIsZero_deploys() public {
        BondingCurveLaunchStrategy deployed = _deployStrategy(INITIAL_TICK, 0);
        assertEq(deployed.graduationTick(), 0);
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
        assertEq(address(strategy.positionManager()), address(positionManager));
        assertEq(address(strategy.poolManager()), address(poolManager));
        assertEq(strategy.initialTick(), INITIAL_TICK);
        assertEq(strategy.graduationTick(), GRADUATION_TICK);
        assertEq(strategy.initialSqrtPriceX96(), TickMath.getSqrtPriceAtTick(INITIAL_TICK));
        assertEq(strategy.graduationSqrtPriceX96(), TickMath.getSqrtPriceAtTick(GRADUATION_TICK));
        assertEq(strategy.curveSupply() + strategy.reserveSupply(), TOTAL_SUPPLY);
        assertApproxEqRel(strategy.curveSupply(), TOTAL_SUPPLY * 80 / 100, 6e15);
    }

    function test_fuzz_WhenConfigurationIsValid_curveLiquidityFitsInSinglePosition(
        int24 initialTick,
        int24 graduationTick
    ) public {
        int24 tickSpacing = strategy.TICK_SPACING();
        // Bands beyond this domain can legitimately revert UnrealizableGraduation (zero ETH principal);
        // within it every deployment must succeed with unclamped curve liquidity.
        graduationTick = int24(bound(graduationTick, 0, 300_000 / tickSpacing)) * tickSpacing;
        initialTick = int24(bound(initialTick, graduationTick / tickSpacing + 1, 600_000 / tickSpacing)) * tickSpacing;

        BondingCurveLaunchStrategy deployed = _deployStrategy(initialTick, graduationTick);
        assertGt(deployed.curveLiquidity(), 0);
        assertLe(deployed.curveLiquidity(), Pool.tickSpacingToMaxLiquidityPerTick(tickSpacing));
    }
}
