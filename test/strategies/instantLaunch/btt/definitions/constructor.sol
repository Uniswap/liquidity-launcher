// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {InstantLaunchTestBase} from "../../base/InstantLaunchTestBase.sol";
import {InstantLaunchStrategy} from "../../../../../src/strategies/InstantLaunchStrategy.sol";
import {FeeSplitter} from "../../../../../src/periphery/FeeSplitter.sol";
import {BeneficiaryVault} from "../../../../../src/periphery/BeneficiaryVault.sol";
import {IFeeSplitter} from "../../../../../src/interfaces/IFeeSplitter.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";

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
/// ├── when the launch floor is not aligned
/// │   └── it reverts with InvalidTickRange
/// ├── when the initial tick cap is not aligned
/// │   └── it reverts with InvalidTickRange
/// ├── when the initial tick exceeds the initial tick cap
/// │   └── it reverts with InvalidTickRange
/// ├── when the initial tick exceeds the maximum usable tick
/// │   └── it reverts with InvalidTickRange
/// ├── when the initial tick does not exceed the launch floor
/// │   └── it reverts with InvalidTickRange
/// ├── when the initial tick cap does not stay below the maximum usable tick
/// │   └── it reverts with InvalidTickRange
/// ├── when the launch floor does not stay above the minimum usable tick
/// │   └── it reverts with InvalidTickRange
/// ├── when the launch range prices the position liquidity above the per-tick maximum
/// │   └── it reverts with InvalidPositionLiquidity
/// └── when the configuration is valid
///     ├── it stores the immutable configuration
///     ├── it derives a position liquidity per orientation that fits in a single position
///     ├── it prices saturating the launch floor tick from either side above the total supply
///     ├── it prices saturating the mirrored launch floor tick from either side above the total supply
///     ├── it prices saturating the maximum initial tick from either side above the blocker cost floors
///     └── it prices saturating the mirrored maximum initial tick from either side above the blocker cost floors
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
            _defaultPoolConfig()
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
        new InstantLaunchStrategy(launcher, POSITION_MANAGER, POOL_MANAGER, mismatched, beneficiaryVault, _defaultPoolConfig());
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
        new InstantLaunchStrategy(launcher, POSITION_MANAGER, POOL_MANAGER, feeSplitter, mismatched, _defaultPoolConfig());
    }

    function test_fuzz_WhenInitialTickIsNotAligned(int24 initialTick) public {
        // Bounded to the valid tick range so alignment is the only violated condition.
        initialTick = int24(bound(initialTick, LOWEST_LAUNCH_TICK, strategy.maxInitialTick()));
        vm.assume(initialTick % strategy.TICK_SPACING() != 0);

        vm.expectRevert(InstantLaunchStrategy.InvalidTickRange.selector);
        _deployStrategy(initialTick);
    }

    function test_fuzz_WhenLaunchFloorIsNotAligned(int24 minLaunchTick) public {
        int24 tickSpacing = strategy.TICK_SPACING();
        // Bounded to the valid floor range so alignment is the only violated condition.
        minLaunchTick =
            int24(bound(minLaunchTick, TickMath.minUsableTick(tickSpacing) + 1, INITIAL_TICK - tickSpacing));
        vm.assume(minLaunchTick % tickSpacing != 0);

        vm.expectRevert(InstantLaunchStrategy.InvalidTickRange.selector);
        _deployStrategy(NATIVE, INITIAL_TICK, minLaunchTick, MAX_INITIAL_TICK);
    }

    function test_fuzz_WhenInitialTickCapIsNotAligned(int24 maxInitialTick) public {
        int24 tickSpacing = strategy.TICK_SPACING();
        // Bounded to the valid cap range so alignment is the only violated condition.
        maxInitialTick = int24(bound(maxInitialTick, INITIAL_TICK, TickMath.maxUsableTick(tickSpacing) - 1));
        vm.assume(maxInitialTick % tickSpacing != 0);

        vm.expectRevert(InstantLaunchStrategy.InvalidTickRange.selector);
        _deployStrategy(NATIVE, INITIAL_TICK, MIN_LAUNCH_TICK, maxInitialTick);
    }

    function test_WhenInitialTickExceedsMaxInitialTick() public {
        int24 firstTickAboveCap = strategy.maxInitialTick() + strategy.TICK_SPACING();
        vm.expectRevert(InstantLaunchStrategy.InvalidTickRange.selector);
        _deployStrategy(firstTickAboveCap);
    }

    function test_fuzz_WhenInitialTickExceedsMaxInitialTick(int24 initialTick) public {
        int24 tickSpacing = strategy.TICK_SPACING();
        // Aligned ticks above the cap, up to and beyond the maximum usable tick.
        initialTick = int24(
            bound(initialTick, strategy.maxInitialTick() / tickSpacing + 1, type(int24).max / tickSpacing)
        ) * tickSpacing;

        vm.expectRevert(InstantLaunchStrategy.InvalidTickRange.selector);
        _deployStrategy(initialTick);
    }

    function test_WhenInitialTickExceedsMaximumUsableTick() public {
        int24 tickSpacing = strategy.TICK_SPACING();
        vm.expectRevert(InstantLaunchStrategy.InvalidTickRange.selector);
        _deployStrategy(TickMath.maxUsableTick(tickSpacing) + tickSpacing);
    }

    function test_WhenInitialTickEqualsLaunchFloor() public {
        int24 floorTick = strategy.minLaunchTick();
        vm.expectRevert(InstantLaunchStrategy.InvalidTickRange.selector);
        _deployStrategy(floorTick);
    }

    function test_fuzz_WhenInitialTickIsBelowLaunchFloor(int24 initialTick) public {
        int24 tickSpacing = strategy.TICK_SPACING();
        // Aligned ticks at or below the launch floor, so the floor check is what reverts rather than alignment.
        initialTick = int24(bound(initialTick, type(int24).min / tickSpacing, strategy.minLaunchTick() / tickSpacing))
            * tickSpacing;

        vm.expectRevert(InstantLaunchStrategy.InvalidTickRange.selector);
        _deployStrategy(initialTick);
    }

    function test_WhenInitialTickCapReachesMaximumUsableTick() public {
        // The cap must stay strictly below the usable range so the mirrored floor does too.
        int24 tickSpacing = strategy.TICK_SPACING();
        vm.expectRevert(InstantLaunchStrategy.InvalidTickRange.selector);
        _deployStrategy(NATIVE, INITIAL_TICK, MIN_LAUNCH_TICK, TickMath.maxUsableTick(tickSpacing));
    }

    function test_WhenLaunchFloorReachesMinimumUsableTick() public {
        // The floor must stay strictly above the usable range so the mirrored cap does too.
        int24 tickSpacing = strategy.TICK_SPACING();
        vm.expectRevert(InstantLaunchStrategy.InvalidTickRange.selector);
        _deployStrategy(NATIVE, INITIAL_TICK, TickMath.minUsableTick(tickSpacing), MAX_INITIAL_TICK);
    }

    function test_WhenLaunchRangeExceedsMaxLiquidityPerTick() public {
        // A one-spacing range this deep prices the full supply above the per-tick liquidity maximum,
        // which would fail the exact-liquidity check on every launch.
        int24 minLaunchTick = -200_000;
        int24 initialTick = minLaunchTick + strategy.TICK_SPACING();

        uint256 liquidity = FullMath.mulDiv(
            TOTAL_SUPPLY,
            FixedPoint96.Q96,
            TickMath.getSqrtPriceAtTick(initialTick) - TickMath.getSqrtPriceAtTick(minLaunchTick)
        );
        assertGt(liquidity, Pool.tickSpacingToMaxLiquidityPerTick(strategy.TICK_SPACING()));

        vm.expectRevert(abi.encodeWithSelector(InstantLaunchStrategy.InvalidPositionLiquidity.selector, liquidity));
        _deployStrategy(NATIVE, initialTick, minLaunchTick, MAX_INITIAL_TICK);
    }

    function test_WhenInitialTickIsLowestLaunchTick_deploys() public {
        InstantLaunchStrategy deployed = _deployStrategy(LOWEST_LAUNCH_TICK);
        assertEq(deployed.initialTick(), LOWEST_LAUNCH_TICK);
    }

    function test_WhenInitialTickIsMaxInitialTick_deploys() public {
        int24 maxInitial = strategy.maxInitialTick();
        InstantLaunchStrategy deployed = _deployStrategy(maxInitial);
        assertEq(deployed.initialTick(), maxInitial);
        assertGt(deployed.positionLiquidity(), 0);
    }

    function test_WhenConfigurationIsValid_storesConfiguration() public view {
        assertEq(strategy.launcher(), launcher);
        assertEq(address(strategy.positionManager()), address(positionManager));
        assertEq(address(strategy.poolManager()), address(poolManager));
        assertEq(address(strategy.feeSplitter()), address(feeSplitter));
        assertEq(address(strategy.beneficiaryVault()), address(beneficiaryVault));
        assertEq(Currency.unwrap(strategy.quoteCurrency()), Currency.unwrap(NATIVE));
        assertEq(strategy.initialTick(), INITIAL_TICK);
        assertEq(strategy.minLaunchTick(), MIN_LAUNCH_TICK);
        assertEq(strategy.maxInitialTick(), MAX_INITIAL_TICK);
        assertEq(strategy.initialSqrtPriceX96(), TickMath.getSqrtPriceAtTick(INITIAL_TICK));
        assertEq(strategy.mirroredInitialSqrtPriceX96(), TickMath.getSqrtPriceAtTick(-INITIAL_TICK));
        assertGt(strategy.positionLiquidity(), 0);
        assertGt(strategy.mirroredPositionLiquidity(), 0);
    }

    function test_WhenConfigurationIsValid_storesErc20QuoteCurrency() public {
        Currency quote = Currency.wrap(HIGH_QUOTE_ADDRESS);
        InstantLaunchStrategy deployed = _deployStrategy(quote, INITIAL_TICK, MIN_LAUNCH_TICK, MAX_INITIAL_TICK);
        assertEq(Currency.unwrap(deployed.quoteCurrency()), HIGH_QUOTE_ADDRESS);
    }

    function test_WhenConfigurationIsValid_saturatingLaunchFloorExceedsTotalSupply() public {
        int24 tickSpacing = strategy.TICK_SPACING();
        int24 floorTick = strategy.minLaunchTick();
        assertEq(floorTick % tickSpacing, 0);
        assertGt(floorTick, TickMath.minUsableTick(tickSpacing));
        assertGt(floorTick - tickSpacing, TickMath.minUsableTick(tickSpacing));

        // positionLiquidity peaks at the lowest deployable tick, leaving the least remaining capacity at
        // the floor, so this deployment prices the cheapest blocker over the whole legal tick domain.
        (uint256 costAbove, uint256 costBelow) = _floorBlockerCosts(_deployStrategy(LOWEST_LAUNCH_TICK));
        assertGt(costAbove, strategy.TOTAL_SUPPLY());
        assertGt(costBelow, strategy.TOTAL_SUPPLY());
    }

    function test_fuzz_WhenConfigurationIsValid_saturatingLaunchFloorExceedsTotalSupply(int24 initialTick) public {
        int24 tickSpacing = strategy.TICK_SPACING();
        initialTick = int24(
            bound(initialTick, LOWEST_LAUNCH_TICK / tickSpacing, strategy.maxInitialTick() / tickSpacing)
        ) * tickSpacing;

        (uint256 costAbove, uint256 costBelow) = _floorBlockerCosts(_deployStrategy(initialTick));
        assertGt(costAbove, strategy.TOTAL_SUPPLY());
        assertGt(costBelow, strategy.TOTAL_SUPPLY());
    }

    function test_fuzz_WhenConfigurationIsValid_saturatingMirroredLaunchFloorExceedsTotalSupply(int24 initialTick)
        public
    {
        int24 tickSpacing = strategy.TICK_SPACING();
        initialTick = int24(
            bound(initialTick, LOWEST_LAUNCH_TICK / tickSpacing, strategy.maxInitialTick() / tickSpacing)
        ) * tickSpacing;

        (uint256 costAbove, uint256 costBelow) = _mirroredFloorBlockerCosts(_deployStrategy(initialTick));
        assertGt(costAbove, strategy.TOTAL_SUPPLY());
        assertGt(costBelow, strategy.TOTAL_SUPPLY());
    }

    /// @notice Tokens an external LP must hold to fill the floor tick's remaining maxLiquidityPerTick with
    ///         the narrowest position on either side of it, which would block every liquidity increase on
    ///         the launch position. `liquidityGross` accrues at both a position's lower and upper tick, so
    ///         the floor can be loaded from the range above it or the range below it.
    function _floorBlockerCosts(InstantLaunchStrategy deployed)
        private
        view
        returns (uint256 costAbove, uint256 costBelow)
    {
        int24 tickSpacing = deployed.TICK_SPACING();
        int24 floorTick = deployed.minLaunchTick();
        uint128 blockerLiquidity = Pool.tickSpacingToMaxLiquidityPerTick(tickSpacing) - deployed.positionLiquidity();

        costAbove = SqrtPriceMath.getAmount1Delta(
            TickMath.getSqrtPriceAtTick(floorTick),
            TickMath.getSqrtPriceAtTick(floorTick + tickSpacing),
            blockerLiquidity,
            true
        );
        costBelow = SqrtPriceMath.getAmount1Delta(
            TickMath.getSqrtPriceAtTick(floorTick - tickSpacing),
            TickMath.getSqrtPriceAtTick(floorTick),
            blockerLiquidity,
            true
        );
    }

    /// @notice The mirrored-orientation equivalent of `_floorBlockerCosts`: the token is currency0,
    ///         the floor mirrors to -minLaunchTick above the price, and blockers there fund in amount0.
    function _mirroredFloorBlockerCosts(InstantLaunchStrategy deployed)
        private
        view
        returns (uint256 costAbove, uint256 costBelow)
    {
        int24 tickSpacing = deployed.TICK_SPACING();
        int24 mirroredFloorTick = -deployed.minLaunchTick();
        uint128 blockerLiquidity =
            Pool.tickSpacingToMaxLiquidityPerTick(tickSpacing) - deployed.mirroredPositionLiquidity();

        costAbove = SqrtPriceMath.getAmount0Delta(
            TickMath.getSqrtPriceAtTick(mirroredFloorTick),
            TickMath.getSqrtPriceAtTick(mirroredFloorTick + tickSpacing),
            blockerLiquidity,
            true
        );
        costBelow = SqrtPriceMath.getAmount0Delta(
            TickMath.getSqrtPriceAtTick(mirroredFloorTick - tickSpacing),
            TickMath.getSqrtPriceAtTick(mirroredFloorTick),
            blockerLiquidity,
            true
        );
    }

    function test_WhenConfigurationIsValid_saturatingMaxInitialTickIsProhibitivelyExpensive() public {
        int24 tickSpacing = strategy.TICK_SPACING();
        int24 capTick = strategy.maxInitialTick();
        assertEq(capTick % tickSpacing, 0);
        assertLt(capTick, TickMath.maxUsableTick(tickSpacing));

        InstantLaunchStrategy deployed = _deployStrategy(capTick);

        // The launch position opens at its upper tick, so the range above that tick is funded in ETH and
        // the range below it in tokens. Both load the same liquidityGross, so both must be costly. The ETH
        // side gets cheaper as the tick rises, which makes the cap the binding deployment for it.
        uint128 blockerLiquidity = Pool.tickSpacingToMaxLiquidityPerTick(tickSpacing) - deployed.positionLiquidity();
        uint256 costAbove = SqrtPriceMath.getAmount0Delta(
            TickMath.getSqrtPriceAtTick(capTick),
            TickMath.getSqrtPriceAtTick(capTick + tickSpacing),
            blockerLiquidity,
            true
        );
        uint256 costBelow = SqrtPriceMath.getAmount1Delta(
            TickMath.getSqrtPriceAtTick(capTick - tickSpacing),
            TickMath.getSqrtPriceAtTick(capTick),
            blockerLiquidity,
            true
        );
        assertGt(costAbove, UPPER_TICK_BLOCKER_COST_FLOOR);
        assertGt(costBelow, strategy.TOTAL_SUPPLY());
    }

    function test_WhenConfigurationIsValid_saturatingMirroredMaxInitialTickIsProhibitivelyExpensive() public {
        int24 tickSpacing = strategy.TICK_SPACING();
        int24 capTick = strategy.maxInitialTick();

        InstantLaunchStrategy deployed = _deployStrategy(capTick);

        // In the mirrored orientation the pool opens at the position's lower tick -capTick: the range
        // below it is funded in the quote currency, the range above it in tokens. The quote-side cost
        // floor is denominated in the quote currency's smallest unit.
        int24 mirroredCapTick = -capTick;
        uint128 blockerLiquidity =
            Pool.tickSpacingToMaxLiquidityPerTick(tickSpacing) - deployed.mirroredPositionLiquidity();
        uint256 costBelowInQuote = SqrtPriceMath.getAmount1Delta(
            TickMath.getSqrtPriceAtTick(mirroredCapTick - tickSpacing),
            TickMath.getSqrtPriceAtTick(mirroredCapTick),
            blockerLiquidity,
            true
        );
        uint256 costAboveInToken = SqrtPriceMath.getAmount0Delta(
            TickMath.getSqrtPriceAtTick(mirroredCapTick),
            TickMath.getSqrtPriceAtTick(mirroredCapTick + tickSpacing),
            blockerLiquidity,
            true
        );
        assertGt(costBelowInQuote, UPPER_TICK_BLOCKER_COST_FLOOR);
        assertGt(costAboveInToken, strategy.TOTAL_SUPPLY());
    }

    function test_fuzz_WhenConfigurationIsValid_positionLiquidityFitsInSinglePosition(int24 initialTick) public {
        int24 tickSpacing = strategy.TICK_SPACING();
        initialTick = int24(
            bound(initialTick, LOWEST_LAUNCH_TICK / tickSpacing, strategy.maxInitialTick() / tickSpacing)
        ) * tickSpacing;

        InstantLaunchStrategy deployed = _deployStrategy(initialTick);
        assertGt(deployed.positionLiquidity(), 0);
        assertLe(deployed.positionLiquidity(), Pool.tickSpacingToMaxLiquidityPerTick(tickSpacing));
        assertGt(deployed.mirroredPositionLiquidity(), 0);
        assertLe(deployed.mirroredPositionLiquidity(), Pool.tickSpacingToMaxLiquidityPerTick(tickSpacing));
    }
}
