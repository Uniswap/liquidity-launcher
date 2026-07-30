// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {InstantLaunchTestBase} from "../../base/InstantLaunchTestBase.sol";
import {InstantLaunchStrategy} from "../../../../../src/strategies/InstantLaunchStrategy.sol";
import {FeeSplitter} from "../../../../../src/periphery/FeeSplitter.sol";
import {BeneficiaryVault} from "../../../../../src/periphery/BeneficiaryVault.sol";
import {IFeeSplitter} from "../../../../../src/interfaces/IFeeSplitter.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";

/// @title ConstructorTest
/// @notice BTT tests for InstantLaunchStrategy.constructor
///
/// constructor
/// ├── when a required address is zero
/// │   └── it reverts with ZeroAddress
/// ├── when the fee splitter uses a different PositionManager
/// │   └── it reverts with PositionManagerMismatch
/// ├── when the beneficiary vault uses a different PositionManager
/// │   └── it reverts with PositionManagerMismatch
/// ├── when the beneficiary vault is zero
/// │   └── it deploys with creator fees disabled
/// ├── when the initial tick is not aligned
/// │   └── it reverts with InvalidTickRange
/// ├── when the initial tick leaves no spacing below the maximum usable tick
/// │   └── it reverts with InvalidTickRange
/// ├── when the initial tick does not exceed the launch floor
/// │   └── it reverts with InvalidTickRange
/// ├── when filling a boundary tick is affordable
/// │   └── it reverts with SaturableBoundaryTick
/// └── when the configuration is valid
///     ├── it stores the immutable configuration
///     ├── it derives a position liquidity that fits in a single position
///     └── it prices filling both boundary ticks out of reach in both currencies
contract ConstructorTest is InstantLaunchTestBase {
    function test_fuzz_WhenRequiredAddressIsZero(uint8 zeroIndex) public {
        // The beneficiary vault is not among the required addresses; see the zero-vault case below.
        zeroIndex = uint8(bound(zeroIndex, 0, 3));

        vm.expectRevert(InstantLaunchStrategy.ZeroAddress.selector);
        new InstantLaunchStrategy(
            zeroIndex == 0 ? address(0) : launcher,
            zeroIndex == 1 ? IPositionManager(address(0)) : IPositionManager(address(positionManager)),
            zeroIndex == 2 ? IPoolManager(address(0)) : poolManager,
            zeroIndex == 3 ? IFeeSplitter(address(0)) : feeSplitter,
            beneficiaryVault,
            INITIAL_TICK
        );
    }

    function test_WhenBeneficiaryVaultIsZero_deploys() public {
        // A zero vault is the opt-out from creator fees: launches leave their position unregistered
        // rather than being rejected at deployment.
        InstantLaunchStrategy deployed = _deployStrategyWithoutBeneficiaryVault();

        assertEq(address(deployed.beneficiaryVault()), address(0));
        assertEq(address(deployed.feeSplitter()), address(feeSplitter));
        assertEq(deployed.initialTick(), INITIAL_TICK);
        assertGt(deployed.positionLiquidity(), 0);
    }

    function test_WhenFeeSplitterUsesDifferentPositionManager() public {
        // A splitter bound to a foreign PositionManager could never collect the launch positions.
        IPositionManager otherPositionManager = IPositionManager(makeAddr("otherPositionManager"));
        // The splitter resolves its PoolManager from the PositionManager at construction.
        vm.mockCall(address(otherPositionManager), abi.encodeWithSignature("poolManager()"), abi.encode(address(0)));
        FeeSplitter mismatched = new FeeSplitter(otherPositionManager, feeSplitter.getSplits());

        vm.expectRevert(
            abi.encodeWithSelector(
                InstantLaunchStrategy.PositionManagerMismatch.selector, address(otherPositionManager)
            )
        );
        new InstantLaunchStrategy(launcher, POSITION_MANAGER, POOL_MANAGER, mismatched, beneficiaryVault, INITIAL_TICK);
    }

    function test_WhenBeneficiaryVaultUsesDifferentPositionManager() public {
        // Registration proves custody against the vault's PositionManager; a mismatch would revert
        // every launch at registration.
        IPositionManager otherPositionManager = IPositionManager(makeAddr("otherPositionManager"));
        BeneficiaryVault mismatched = new BeneficiaryVault(otherPositionManager, tokenJar, address(0xdead));

        vm.expectRevert(
            abi.encodeWithSelector(
                InstantLaunchStrategy.PositionManagerMismatch.selector, address(otherPositionManager)
            )
        );
        new InstantLaunchStrategy(launcher, POSITION_MANAGER, POOL_MANAGER, feeSplitter, mismatched, INITIAL_TICK);
    }

    function test_fuzz_WhenInitialTickIsNotAligned(int24 initialTick) public {
        initialTick = int24(bound(initialTick, LOWEST_LAUNCH_TICK, TickMath.maxUsableTick(strategy.TICK_SPACING())));
        vm.assume(initialTick % strategy.TICK_SPACING() != 0);

        vm.expectRevert(InstantLaunchStrategy.InvalidTickRange.selector);
        _deployStrategy(initialTick);
    }

    function test_WhenInitialTickExceedsMaximumUsableTick() public {
        int24 tickSpacing = strategy.TICK_SPACING();
        vm.expectRevert(InstantLaunchStrategy.InvalidTickRange.selector);
        _deployStrategy(TickMath.maxUsableTick(tickSpacing) + tickSpacing);
    }

    function test_WhenInitialTickLeavesNoSpacingBelowMaximumUsableTick() public {
        // The band above the upper boundary prices its native door, so the top spacing is not deployable:
        // there is no tick above `maxUsableTick` to form it with.
        int24 maxUsable = TickMath.maxUsableTick(strategy.TICK_SPACING());

        vm.expectRevert(InstantLaunchStrategy.InvalidTickRange.selector);
        _deployStrategy(maxUsable);
    }

    function test_WhenInitialTickEqualsLaunchFloor() public {
        int24 floorTick = strategy.MIN_LAUNCH_TICK();
        vm.expectRevert(InstantLaunchStrategy.InvalidTickRange.selector);
        _deployStrategy(floorTick);
    }

    function test_fuzz_WhenInitialTickIsBelowLaunchFloor(int24 initialTick) public {
        int24 tickSpacing = strategy.TICK_SPACING();
        // Aligned ticks at or below the launch floor, so the floor check is what reverts rather than alignment.
        initialTick = int24(bound(initialTick, type(int24).min / tickSpacing, strategy.MIN_LAUNCH_TICK() / tickSpacing))
            * tickSpacing;

        vm.expectRevert(InstantLaunchStrategy.InvalidTickRange.selector);
        _deployStrategy(initialTick);
    }

    function test_WhenInitialTickIsLowestLaunchTick_deploys() public {
        InstantLaunchStrategy deployed = _deployStrategy(LOWEST_LAUNCH_TICK);
        assertEq(deployed.initialTick(), LOWEST_LAUNCH_TICK);
    }

    function test_WhenInitialTickIsHighestLaunchTick_deploys() public {
        InstantLaunchStrategy deployed = _deployStrategy(HIGHEST_LAUNCH_TICK);
        assertEq(deployed.initialTick(), HIGHEST_LAUNCH_TICK);
    }

    function test_WhenInitialTickIsOneSpacingAboveHighestLaunchTick() public {
        // One spacing higher and the upper boundary's native door drops under MIN_NATIVE_PIN_COST. Asserting
        // the exact edge means a change to the supply, the spacing or the cap cannot move it unnoticed.
        int24 rejected = HIGHEST_LAUNCH_TICK + strategy.TICK_SPACING();
        uint256 nativeCost = _expectedNativeCost(rejected);

        vm.expectRevert(
            abi.encodeWithSelector(InstantLaunchStrategy.SaturableBoundaryTick.selector, rejected, nativeCost)
        );
        _deployStrategy(rejected);
        assertLe(nativeCost, strategy.MIN_NATIVE_PIN_COST(), "the rejected tick was affordable for another reason");
    }

    function test_WhenConfigurationIsValid_storesConfiguration() public view {
        assertEq(strategy.launcher(), launcher);
        assertEq(address(strategy.positionManager()), address(positionManager));
        assertEq(address(strategy.poolManager()), address(poolManager));
        assertEq(address(strategy.feeSplitter()), address(feeSplitter));
        assertEq(address(strategy.beneficiaryVault()), address(beneficiaryVault));
        assertEq(strategy.initialTick(), INITIAL_TICK);
        assertEq(strategy.initialSqrtPriceX96(), TickMath.getSqrtPriceAtTick(INITIAL_TICK));
        assertGt(strategy.positionLiquidity(), 0);
    }

    function test_WhenConfigurationIsValid_saturatingLaunchFloorExceedsTotalSupply() public view {
        int24 tickSpacing = strategy.TICK_SPACING();
        int24 floorTick = strategy.MIN_LAUNCH_TICK();
        assertEq(floorTick % tickSpacing, 0);
        assertGt(floorTick, TickMath.minUsableTick(tickSpacing));

        // Tokens an external LP must hold to fill the floor tick's remaining maxLiquidityPerTick, using the
        // narrowest position below it — the cheapest way to do so, and enough to block every liquidity
        // increase on the launch position. Rounded down, since a blocker only needs the least that works.
        uint128 blockerLiquidity = Pool.tickSpacingToMaxLiquidityPerTick(tickSpacing) - strategy.positionLiquidity();
        uint256 blockerCost = SqrtPriceMath.getAmount1Delta(
            TickMath.getSqrtPriceAtTick(floorTick - tickSpacing),
            TickMath.getSqrtPriceAtTick(floorTick),
            blockerLiquidity,
            false
        );
        assertGt(blockerCost, strategy.TOTAL_SUPPLY());
    }

    function test_fuzz_WhenConfigurationIsValid_positionLiquidityFitsInSinglePosition(int24 initialTick) public {
        int24 tickSpacing = strategy.TICK_SPACING();
        initialTick = int24(bound(initialTick, LOWEST_LAUNCH_TICK / tickSpacing, HIGHEST_LAUNCH_TICK / tickSpacing))
            * tickSpacing;

        InstantLaunchStrategy deployed = _deployStrategy(initialTick);
        assertGt(deployed.positionLiquidity(), 0);
        assertLt(deployed.positionLiquidity(), Pool.tickSpacingToMaxLiquidityPerTick(tickSpacing));
    }

    /// @dev The invariant the constructor exists to enforce, recomputed independently of it: for any tick it
    ///      accepts, filling either boundary tick costs more than the supply in token and more than
    ///      MIN_NATIVE_PIN_COST in native. Both bands per boundary are priced, so the cheapest is covered.
    function test_fuzz_WhenConfigurationIsValid_neitherBoundaryTickIsFillable(int24 initialTick) public {
        int24 tickSpacing = strategy.TICK_SPACING();
        initialTick = int24(bound(initialTick, LOWEST_LAUNCH_TICK / tickSpacing, HIGHEST_LAUNCH_TICK / tickSpacing))
            * tickSpacing;

        InstantLaunchStrategy deployed = _deployStrategy(initialTick);
        uint128 headroom = Pool.tickSpacingToMaxLiquidityPerTick(tickSpacing) - deployed.positionLiquidity();

        int24[2] memory boundaries = [deployed.MIN_LAUNCH_TICK(), initialTick];
        for (uint256 i; i < boundaries.length; i++) {
            int24 boundary = boundaries[i];
            uint160 below = TickMath.getSqrtPriceAtTick(boundary - tickSpacing);
            uint160 at = TickMath.getSqrtPriceAtTick(boundary);
            uint160 above = TickMath.getSqrtPriceAtTick(boundary + tickSpacing);

            assertGt(SqrtPriceMath.getAmount1Delta(below, at, headroom, false), deployed.TOTAL_SUPPLY());
            assertGt(SqrtPriceMath.getAmount1Delta(at, above, headroom, false), deployed.TOTAL_SUPPLY());
            assertGt(SqrtPriceMath.getAmount0Delta(at, above, headroom, false), deployed.MIN_NATIVE_PIN_COST());
            assertGt(SqrtPriceMath.getAmount0Delta(below, at, headroom, false), deployed.MIN_NATIVE_PIN_COST());
        }
    }

    /// @dev Every aligned tick above the ceiling is rejected, not only the first one: the native door gets
    ///      monotonically cheaper as the tick rises, which is the property the constructor's single
    ///      upper-boundary check relies on.
    function test_fuzz_WhenUpperBoundaryIsAffordable(int24 initialTick) public {
        int24 tickSpacing = strategy.TICK_SPACING();
        initialTick = int24(
            bound(
                initialTick,
                HIGHEST_LAUNCH_TICK / tickSpacing + 1,
                TickMath.maxUsableTick(tickSpacing) / tickSpacing - 1
            )
        ) * tickSpacing;

        vm.expectRevert(
            abi.encodeWithSelector(
                InstantLaunchStrategy.SaturableBoundaryTick.selector, initialTick, _expectedNativeCost(initialTick)
            )
        );
        _deployStrategy(initialTick);
    }

    /// @dev The cheapest native blocker at `initialTick`, mirroring the constructor's pricing.
    function _expectedNativeCost(int24 initialTick) internal view returns (uint256) {
        int24 tickSpacing = strategy.TICK_SPACING();
        uint128 headroom = Pool.tickSpacingToMaxLiquidityPerTick(tickSpacing)
            - _expectedPositionLiquidity(initialTick, strategy.MIN_LAUNCH_TICK());
        return SqrtPriceMath.getAmount0Delta(
            TickMath.getSqrtPriceAtTick(initialTick),
            TickMath.getSqrtPriceAtTick(initialTick + tickSpacing),
            headroom,
            false
        );
    }

    /// @dev Mirrors the constructor's own derivation, for tests that need it before deployment.
    function _expectedPositionLiquidity(int24 initialTick, int24 floorTick) internal pure returns (uint128) {
        return SafeCastLib.toUint128(
            FullMath.mulDiv(
                TOTAL_SUPPLY,
                FixedPoint96.Q96,
                uint256(TickMath.getSqrtPriceAtTick(initialTick) - TickMath.getSqrtPriceAtTick(floorTick))
            )
        );
    }
}
