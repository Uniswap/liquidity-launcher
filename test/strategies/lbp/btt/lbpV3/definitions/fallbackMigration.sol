// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LBPStrategyTestBase} from "../../../base/LBPStrategyTestBase.sol";
import {ILBPStrategy} from "src/interfaces/ILBPStrategy.sol";
import {ILBPInitializer, LBPInitializationParams} from "src/interfaces/ILBPInitializer.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {
    MigratorParams,
    MigratorParameters,
    LiquidityAllocationBracket,
    PoolParameters
} from "src/libraries/MigratorParams.sol";
import {PositionPlanner} from "src/libraries/PositionPlanner.sol";
import {PositionDefinition} from "src/types/PositionPlannerTypes.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IInitializerHook} from "src/interfaces/IInitializerHook.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {MockLBPInitializer} from "test/mocks/MockLBPInitializer.sol";
import {MockReentrantFallbackMigrationRecipient} from "test/mocks/MockReentrantFallbackMigrationRecipient.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";

/// @notice A hook that passes registration checks but reverts when PoolManager initializes the configured pool.
contract MaliciousBeforeInitializeHook {
    address public immutable authorized;

    constructor(address _authorized) {
        authorized = _authorized;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IInitializerHook).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert("MALICIOUS_HOOK");
    }
}

/// @title FallbackMigrationTest
/// @notice Tests for the migrate() waterfall: configured migration -> full-range fallback -> release.
contract FallbackMigrationTest is LBPStrategyTestBase {
    /// @notice Tier 2 preserves the configured hook, so a hook that blocks tier 1 also blocks fallback.
    function test_FallbackReleasesWhenConfiguredHookReverts() public {
        (
            MigratorParameters memory mp,
            uint128 totalSupply,
            LiquidityAllocationBracket[] memory brackets,
            LBPInitializationParams memory lbpParams
        ) = _fallbackSuccessParams();

        mp.poolParameters.hook = _installRevertingInitializerHook();

        (MockLBPInitializer initializer, MockERC20 token) =
            _initializeWith(mp, totalSupply, uint64(block.number), brackets, address(0), lbpParams);
        vm.deal(address(initializer), lbpParams.currencyRaised);
        vm.roll(mp.migrationBlock);

        uint256 ethBefore = recipient.balance;
        uint256 tokenBefore = token.balanceOf(recipient);

        vm.expectEmit(true, true, false, true, address(strategy));
        emit ILBPStrategy.FundsRecovered(ILBPInitializer(address(initializer)), recipient, mp.reservedTokenAmountForLP);
        strategy.migrate(ILBPInitializer(address(initializer)));

        assertEq(recipient.balance, ethBefore + lbpParams.currencyRaised);
        assertEq(token.balanceOf(recipient), tokenBefore + mp.reservedTokenAmountForLP);
        assertEq(strategy.reserves(ILBPInitializer(address(initializer))), 0);
        assertEq(address(initializer).balance, 0);
    }

    /// @notice Tier 1 must not emit Migrated when the configured position plan resolves to no positions.
    function test_FallbackMigratesWhenConfiguredPlanResolvesNoResolvedPositions() public {
        (
            MigratorParameters memory mp,
            uint128 totalSupply,
            LiquidityAllocationBracket[] memory brackets,
            LBPInitializationParams memory lbpParams
        ) = _fallbackSuccessParams();

        mp.reservedTokenAmountForLP = 1e30;
        totalSupply = mp.reservedTokenAmountForLP + 10 ether;
        lbpParams.currencyRaised = 1e30;
        lbpParams.tokensSold = 1 ether;
        mp.poolParameters.tickSpacing = 1;

        PositionDefinition[] memory defs = new PositionDefinition[](1);
        defs[0] = PositionDefinition({offsetLower: -1, offsetUpper: 1, weight: PositionPlanner.MPS});
        mp.positionDefinitions = abi.encode(defs);

        (MockLBPInitializer initializer, MockERC20 token) =
            _initializeWith(mp, totalSupply, uint64(block.number), brackets, address(0), lbpParams);
        vm.deal(address(initializer), lbpParams.currencyRaised);
        vm.roll(mp.migrationBlock);

        PoolKey memory key = _nativePoolKey(address(token), mp.poolParameters);

        vm.expectEmit(true, true, false, false, address(strategy));
        emit ILBPStrategy.FallbackMigrated(ILBPInitializer(address(initializer)), key, 0, 0, 0);
        strategy.migrate(ILBPInitializer(address(initializer)));

        assertGt(POSITION_MANAGER.nextTokenId(), 1);
        assertEq(strategy.reserves(ILBPInitializer(address(initializer))), 0);
    }

    /// @notice Fallback preserves lpAllocationSchedule; it does not use the full raise as the LP budget.
    function test_FallbackPreservesBracketScheduleWhenConfiguredPlanResolvesNoResolvedPositions() public {
        (
            MigratorParameters memory mp,
            uint128 totalSupply,
            LiquidityAllocationBracket[] memory brackets,
            LBPInitializationParams memory lbpParams
        ) = _fallbackSuccessParams();
        brackets[0] = LiquidityAllocationBracket({lowerThreshold: 0, rate: MigratorParams.MAX_BRACKET_RATE / 2});

        mp.reservedTokenAmountForLP = 1e30;
        totalSupply = mp.reservedTokenAmountForLP + 10 ether;
        lbpParams.currencyRaised = 1e30;
        lbpParams.tokensSold = 1 ether;
        // Override the pool parameters to use a tick spacing of 1
        mp.poolParameters.tickSpacing = 1;

        PositionDefinition[] memory defs = new PositionDefinition[](1);
        defs[0] = PositionDefinition({offsetLower: -1, offsetUpper: 1, weight: PositionPlanner.MPS});
        mp.positionDefinitions = abi.encode(defs);

        (MockLBPInitializer initializer, MockERC20 token) =
            _initializeWith(mp, totalSupply, uint64(block.number), brackets, address(0), lbpParams);
        vm.deal(address(initializer), lbpParams.currencyRaised);
        vm.roll(mp.migrationBlock);

        uint256 recipientBefore = recipient.balance;
        uint256 poolBefore = address(POOL_MANAGER).balance;

        strategy.migrate(ILBPInitializer(address(initializer)));

        assertApproxEqAbs(address(POOL_MANAGER).balance - poolBefore, lbpParams.currencyRaised / 2, 1e12);
        assertApproxEqAbs(recipient.balance - recipientBefore, lbpParams.currencyRaised / 2, 1e12);
        assertEq(token.balanceOf(address(strategy)), 0);
    }

    /// @notice A swept-vs-claimed mismatch makes both migration tiers revert and releases assets.
    function test_FallbackReleasesWhenCurrencySweptMismatchesClaimedRaise(MigrationFuzzParams memory p) public {
        LiquidityAllocationBracket[] memory brackets = _boundBrackets(p.bpParams);
        (MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock,) = _boundMigratorParams(p);

        LBPInitializationParams memory lbpParams =
            LBPInitializationParams({initialPriceX96: uint160(1 << 96), tokensSold: 1, currencyRaised: 2});
        (MockLBPInitializer initializer, MockERC20 token) =
            _initializeWith(mp, totalSupply, endBlock, brackets, address(0), lbpParams);
        vm.deal(address(initializer), 1);
        vm.roll(mp.migrationBlock);

        uint256 ethBefore = recipient.balance;
        uint256 tokenBefore = token.balanceOf(recipient);

        vm.expectEmit(true, true, false, true, address(strategy));
        emit ILBPStrategy.FundsRecovered(ILBPInitializer(address(initializer)), recipient, mp.reservedTokenAmountForLP);
        strategy.migrate(ILBPInitializer(address(initializer)));

        assertEq(recipient.balance, ethBefore + 1);
        assertEq(token.balanceOf(recipient), tokenBefore + mp.reservedTokenAmountForLP);
        assertEq(strategy.reserves(ILBPInitializer(address(initializer))), 0);
        assertEq(address(initializer).balance, 0);
    }

    /// @notice Invalid price makes both migration tiers revert and releases assets.
    function test_FallbackReleasesWhenFallbackPriceIsInvalid(MigrationFuzzParams memory p) public {
        LiquidityAllocationBracket[] memory brackets = _boundBrackets(p.bpParams);
        (MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock,) = _boundMigratorParams(p);

        LBPInitializationParams memory lbpParams =
            LBPInitializationParams({initialPriceX96: 0, tokensSold: 1, currencyRaised: 1});
        (MockLBPInitializer initializer, MockERC20 token) =
            _initializeWith(mp, totalSupply, endBlock, brackets, address(0), lbpParams);
        vm.deal(address(initializer), 1);
        vm.roll(mp.migrationBlock);

        uint256 ethBefore = recipient.balance;
        uint256 tokenBefore = token.balanceOf(recipient);

        vm.expectEmit(true, true, false, true, address(strategy));
        emit ILBPStrategy.FundsRecovered(ILBPInitializer(address(initializer)), recipient, mp.reservedTokenAmountForLP);
        strategy.migrate(ILBPInitializer(address(initializer)));

        assertEq(recipient.balance, ethBefore + 1);
        assertEq(token.balanceOf(recipient), tokenBefore + mp.reservedTokenAmountForLP);
        assertEq(strategy.reserves(ILBPInitializer(address(initializer))), 0);
    }

    /// @notice If the strategy-hook pool is already initialized, tier 2 reverts and tier 3 releases assets.
    function test_FallbackReleasesWhenStrategyHookPoolInitializationFails() public {
        (
            MigratorParameters memory mp,
            uint128 totalSupply,
            LiquidityAllocationBracket[] memory brackets,
            LBPInitializationParams memory lbpParams
        ) = _fallbackSuccessParams();
        (MockLBPInitializer initializer, MockERC20 token) =
            _initializeWith(mp, totalSupply, uint64(block.number), brackets, address(0), lbpParams);
        vm.deal(address(initializer), lbpParams.currencyRaised);

        PoolKey memory rawKey = _nativePoolKey(
            address(token),
            PoolParameters({fee: mp.poolParameters.fee, tickSpacing: mp.poolParameters.tickSpacing, hook: address(0)})
        );
        PoolKey memory strategyKey = _nativePoolKey(
            address(token),
            PoolParameters({
                fee: mp.poolParameters.fee, tickSpacing: mp.poolParameters.tickSpacing, hook: address(strategy)
            })
        );
        POOL_MANAGER.initialize(rawKey, uint160(1 << 96));
        vm.prank(address(strategy));
        POOL_MANAGER.initialize(strategyKey, uint160(1 << 96));

        vm.roll(mp.migrationBlock);

        uint256 ethBefore = recipient.balance;
        uint256 tokenBefore = token.balanceOf(recipient);

        vm.expectEmit(true, true, false, true, address(strategy));
        emit ILBPStrategy.FundsRecovered(ILBPInitializer(address(initializer)), recipient, mp.reservedTokenAmountForLP);
        strategy.migrate(ILBPInitializer(address(initializer)));

        assertEq(recipient.balance, ethBefore + lbpParams.currencyRaised);
        assertEq(token.balanceOf(recipient), tokenBefore + mp.reservedTokenAmountForLP);
        assertEq(strategy.reserves(ILBPInitializer(address(initializer))), 0);
    }

    /// @notice If PositionManager rejects both tier plans, tier 3 releases the swept assets.
    function test_FallbackReleasesWhenPositionManagerAlwaysReverts() public {
        (
            MigratorParameters memory mp,
            uint128 totalSupply,
            LiquidityAllocationBracket[] memory brackets,
            LBPInitializationParams memory lbpParams
        ) = _fallbackSuccessParams();
        (MockLBPInitializer initializer, MockERC20 token) =
            _initializeWith(mp, totalSupply, uint64(block.number), brackets, address(0), lbpParams);
        vm.deal(address(initializer), lbpParams.currencyRaised);
        vm.roll(mp.migrationBlock);

        vm.mockCallRevert(
            address(POSITION_MANAGER), abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector), "PM_FAILED"
        );

        uint256 ethBefore = recipient.balance;
        uint256 tokenBefore = token.balanceOf(recipient);

        vm.expectEmit(true, true, false, true, address(strategy));
        emit ILBPStrategy.FundsRecovered(ILBPInitializer(address(initializer)), recipient, mp.reservedTokenAmountForLP);
        strategy.migrate(ILBPInitializer(address(initializer)));

        assertEq(recipient.balance, ethBefore + lbpParams.currencyRaised);
        assertEq(token.balanceOf(recipient), tokenBefore + mp.reservedTokenAmountForLP);
        assertEq(strategy.reserves(ILBPInitializer(address(initializer))), 0);
    }

    /// @notice A malicious recipient cannot reenter migrate during release.
    function test_fuzz_migrateReentryViaLeftoverRecipient_revertsWithReentrancy(MigrationFuzzParams memory p) public {
        MockReentrantFallbackMigrationRecipient recipient =
            new MockReentrantFallbackMigrationRecipient(ILBPStrategy(address(strategy)));

        LiquidityAllocationBracket[] memory brackets = _boundBrackets(p.bpParams);
        (MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock,) = _boundMigratorParams(p);
        mp.recipient = address(recipient);

        LBPInitializationParams memory lbpParams =
            LBPInitializationParams({initialPriceX96: 0, tokensSold: 0, currencyRaised: 2});
        (MockLBPInitializer initializer,) = _initializeWith(mp, totalSupply, endBlock, brackets, address(0), lbpParams);
        vm.deal(address(initializer), 1);
        recipient.setInitializer(ILBPInitializer(address(initializer)));

        vm.roll(mp.migrationBlock);
        strategy.migrate(ILBPInitializer(address(initializer)));

        assertTrue(recipient.reentered());
        assertEq(bytes4(recipient.capturedRevertData()), ReentrancyGuardTransient.Reentrancy.selector);
    }

    function _fallbackSuccessParams()
        private
        view
        returns (
            MigratorParameters memory mp,
            uint128 totalSupply,
            LiquidityAllocationBracket[] memory brackets,
            LBPInitializationParams memory lbpParams
        )
    {
        brackets = new LiquidityAllocationBracket[](1);
        brackets[0] = LiquidityAllocationBracket({lowerThreshold: 0, rate: MigratorParams.MAX_BRACKET_RATE});

        PositionDefinition[] memory defs = new PositionDefinition[](1);
        defs[0] = PositionDefinition({offsetLower: TickMath.MIN_TICK, offsetUpper: TickMath.MAX_TICK, weight: 1e7});

        mp = MigratorParameters({
            migrationBlock: uint64(block.number + 1),
            reservedTokenAmountForLP: 100 ether,
            recipient: recipient,
            positionRecipient: positionRecipient,
            poolParameters: PoolParameters({fee: 3000, tickSpacing: 60, hook: address(0)}),
            token: address(0),
            currency: address(0),
            positionDefinitions: abi.encode(defs),
            lpAllocationSchedule: new bytes(0)
        });
        totalSupply = mp.reservedTokenAmountForLP + 10 ether;
        lbpParams = LBPInitializationParams({
            initialPriceX96: uint160(1 << 96), tokensSold: 1 ether, currencyRaised: 100 ether
        });
    }

    function _installRevertingInitializerHook() private returns (address hookAddr) {
        hookAddr = address(uint160(Hooks.BEFORE_INITIALIZE_FLAG));
        MaliciousBeforeInitializeHook impl = new MaliciousBeforeInitializeHook(address(strategy));
        vm.etch(hookAddr, address(impl).code);
    }

    function _nativePoolKey(address token, PoolParameters memory poolParameters) private pure returns (PoolKey memory) {
        Currency c0 = Currency.wrap(address(0));
        Currency c1 = Currency.wrap(token);
        if (uint160(address(0)) > uint160(token)) {
            (c0, c1) = (c1, c0);
        }
        return PoolKey({
            currency0: c0,
            currency1: c1,
            fee: poolParameters.fee,
            tickSpacing: poolParameters.tickSpacing,
            hooks: IHooks(poolParameters.hook)
        });
    }
}
