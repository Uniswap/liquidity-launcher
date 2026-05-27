// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LBPStrategyTestBase} from "../../../base/LBPStrategyTestBase.sol";
import {ILBPStrategy} from "src/interfaces/ILBPStrategy.sol";
import {ILBPInitializer, LBPInitializationParams} from "src/interfaces/ILBPInitializer.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {MigratorParameters, LiquidityAllocationBracket} from "src/libraries/MigratorParams.sol";
import {PositionPlanner} from "src/libraries/PositionPlanner.sol";
import {PositionDefinition} from "src/types/PositionPlannerTypes.sol";
import {Plan, Position} from "src/types/PositionPlannerTypes.sol";
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

/// @notice A standalone mock that passes the strategy's hook registration checks (ERC165 +
/// `authorized() == strategy`) but reverts on every `beforeInitialize`. Models a hook that is well-formed at
/// registration time but goes rogue (buggy, paused, or adversarial) by the time migration runs.
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
/// @notice BTT tests for the migrate() waterfall: configured tryMigrate → full-range tryMigrate → release.
/// @dev Pending future PR work: the planner-grief case (positions resolve to empty) is not yet covered here
///      because `tryMigrate` currently doesn't revert on a zero-position resolution, so the fallback path
///      isn't reachable for that scenario. Will be added once the position-count revert lands on
///      `feat/tryMigrate`.
contract FallbackMigrationTest is LBPStrategyTestBase {
    /// @notice A malicious configured hook blocks both attempts because fallback preserves the configured hook.
    function test_FallbackReleasesWhenConfiguredHookReverts() public {
        (
            MigratorParameters memory mp,
            uint128 totalSupply,
            LiquidityAllocationBracket[] memory brackets,
            LBPInitializationParams memory lbpParams
        ) = _fallbackSuccessParams();

        address hookAddr = address(uint160(Hooks.BEFORE_INITIALIZE_FLAG));
        MaliciousBeforeInitializeHook impl = new MaliciousBeforeInitializeHook(address(strategy));
        vm.etch(hookAddr, address(impl).code);
        mp.hook = hookAddr;

        (MockLBPInitializer initializer, MockERC20 token) =
            _initializeWith(mp, totalSupply, uint64(block.number), brackets, address(0), lbpParams);
        vm.deal(address(initializer), lbpParams.currencyRaised);
        vm.roll(mp.migrationBlock);

        uint256 ethBefore = leftoverRecipient.balance;
        uint256 tokenBefore = token.balanceOf(leftoverRecipient);
        uint256 nextTokenIdBefore = POSITION_MANAGER.nextTokenId();

        vm.expectEmit(true, true, false, false, address(strategy));
        emit ILBPStrategy.FundsRecovered(ILBPInitializer(address(initializer)), leftoverRecipient, mp.supplyForLP);
        strategy.migrate(ILBPInitializer(address(initializer)));

        assertEq(leftoverRecipient.balance, ethBefore + lbpParams.currencyRaised);
        assertEq(token.balanceOf(leftoverRecipient), tokenBefore + mp.supplyForLP);
        assertEq(POSITION_MANAGER.nextTokenId(), nextTokenIdBefore);
        assertEq(strategy.reserves(ILBPInitializer(address(initializer))), 0);
    }

    /// @notice Release: both migration attempts detect no swept currency and revert.
    function test_FallbackReleasesWhenCurrencySweptIsZero(MigrationFuzzParams memory p) public {
        LiquidityAllocationBracket[] memory brackets = _boundBrackets(p.bpParams);
        (MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock,) = _boundMigratorParams(p);

        // currencyRaised = 0 means tier-1 will try to initialize a pool with sqrtPrice=0 → reverts.
        LBPInitializationParams memory lbpParams =
            LBPInitializationParams({initialPriceX96: 0, tokensSold: 0, currencyRaised: 0});
        (MockLBPInitializer initializer, MockERC20 token) =
            _initializeWith(mp, totalSupply, endBlock, brackets, address(0), lbpParams);

        vm.roll(mp.migrationBlock);

        uint256 ethBefore = leftoverRecipient.balance;
        uint256 tokenBefore = token.balanceOf(leftoverRecipient);

        vm.expectEmit(true, true, false, true, address(strategy));
        emit ILBPStrategy.FundsRecovered(ILBPInitializer(address(initializer)), leftoverRecipient, mp.supplyForLP);
        strategy.migrate(ILBPInitializer(address(initializer)));

        assertEq(leftoverRecipient.balance, ethBefore);
        assertEq(token.balanceOf(leftoverRecipient), tokenBefore + mp.supplyForLP);
        assertEq(strategy.reserves(ILBPInitializer(address(initializer))), 0);
    }

    /// @notice Tier-2 release: swept currency doesn't match reported raise.
    function test_FallbackReleasesWhenCurrencySweptMismatchesClaimedRaise(MigrationFuzzParams memory p) public {
        LiquidityAllocationBracket[] memory brackets = _boundBrackets(p.bpParams);
        (MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock,) = _boundMigratorParams(p);

        LBPInitializationParams memory lbpParams =
            LBPInitializationParams({initialPriceX96: uint160(1 << 96), tokensSold: 1, currencyRaised: 2});
        (MockLBPInitializer initializer, MockERC20 token) =
            _initializeWith(mp, totalSupply, endBlock, brackets, address(0), lbpParams);
        vm.deal(address(initializer), 1);
        vm.roll(mp.migrationBlock);

        uint256 ethBefore = leftoverRecipient.balance;
        uint256 tokenBefore = token.balanceOf(leftoverRecipient);

        vm.expectEmit(true, true, false, true, address(strategy));
        emit ILBPStrategy.FundsRecovered(ILBPInitializer(address(initializer)), leftoverRecipient, mp.supplyForLP);
        strategy.migrate(ILBPInitializer(address(initializer)));

        assertEq(leftoverRecipient.balance, ethBefore + 1);
        assertEq(token.balanceOf(leftoverRecipient), tokenBefore + mp.supplyForLP);
        assertEq(strategy.reserves(ILBPInitializer(address(initializer))), 0);
    }

    /// @notice Tier-2 release: initialPriceX96 == 0 with nonzero raise → InvalidPrice reason.
    function test_FallbackReleasesWhenFallbackPriceIsInvalid(MigrationFuzzParams memory p) public {
        LiquidityAllocationBracket[] memory brackets = _boundBrackets(p.bpParams);
        (MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock,) = _boundMigratorParams(p);

        LBPInitializationParams memory lbpParams =
            LBPInitializationParams({initialPriceX96: 0, tokensSold: 1, currencyRaised: 1});
        (MockLBPInitializer initializer, MockERC20 token) =
            _initializeWith(mp, totalSupply, endBlock, brackets, address(0), lbpParams);
        vm.deal(address(initializer), 1);
        vm.roll(mp.migrationBlock);

        uint256 ethBefore = leftoverRecipient.balance;
        uint256 tokenBefore = token.balanceOf(leftoverRecipient);

        vm.expectEmit(true, true, false, true, address(strategy));
        emit ILBPStrategy.FundsRecovered(ILBPInitializer(address(initializer)), leftoverRecipient, mp.supplyForLP);
        strategy.migrate(ILBPInitializer(address(initializer)));

        assertEq(leftoverRecipient.balance, ethBefore + 1);
        assertEq(token.balanceOf(leftoverRecipient), tokenBefore + mp.supplyForLP);
        assertEq(strategy.reserves(ILBPInitializer(address(initializer))), 0);
    }

    /// @notice Tier-2 release: strategy-hook pool was pre-initialized → tier-2's initialize reverts.
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

        // Pre-initialize the hookless pool so tier-1's `_getPoolKey` falls back to strategy-hook, AND
        // pre-initialize that strategy-hook pool too — so BOTH tier-1's initialize and tier-2's initialize revert.
        PoolKey memory rawKey = _nativePoolKey(address(token), mp.poolLPFee, mp.poolTickSpacing, address(0));
        PoolKey memory strategyKey = _nativePoolKey(address(token), mp.poolLPFee, mp.poolTickSpacing, address(strategy));
        POOL_MANAGER.initialize(rawKey, uint160(1 << 96));
        vm.prank(address(strategy));
        POOL_MANAGER.initialize(strategyKey, uint160(1 << 96));

        vm.roll(mp.migrationBlock);

        uint256 ethBefore = leftoverRecipient.balance;
        uint256 tokenBefore = token.balanceOf(leftoverRecipient);

        vm.expectEmit(true, true, false, true, address(strategy));
        emit ILBPStrategy.FundsRecovered(ILBPInitializer(address(initializer)), leftoverRecipient, mp.supplyForLP);
        strategy.migrate(ILBPInitializer(address(initializer)));

        assertEq(leftoverRecipient.balance, ethBefore + lbpParams.currencyRaised);
        assertEq(token.balanceOf(leftoverRecipient), tokenBefore + mp.supplyForLP);
        assertEq(strategy.reserves(ILBPInitializer(address(initializer))), 0);
    }

    /// @notice Release: every modifyLiquidities call reverts, so both migration attempts fail.
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

        // Selector-only mock: every modifyLiquidities call reverts. Both the mint and the sweep-back in tier-2.
        vm.mockCallRevert(
            address(POSITION_MANAGER), abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector), "PM_FAILED"
        );

        uint256 ethBefore = leftoverRecipient.balance;
        uint256 tokenBefore = token.balanceOf(leftoverRecipient);

        vm.expectEmit(true, true, false, true, address(strategy));
        emit ILBPStrategy.FundsRecovered(ILBPInitializer(address(initializer)), leftoverRecipient, mp.supplyForLP);
        strategy.migrate(ILBPInitializer(address(initializer)));

        assertEq(leftoverRecipient.balance, ethBefore + lbpParams.currencyRaised);
        assertEq(token.balanceOf(leftoverRecipient), tokenBefore + mp.supplyForLP);
        assertEq(strategy.reserves(ILBPInitializer(address(initializer))), 0);
    }

    /// @notice Reentrancy: malicious leftoverRecipient tries to call migrate() from its receive() during the
    /// release leg. The outer migrate's nonReentrant guard rejects it.
    function test_fuzz_migrateReentryViaLeftoverRecipient_revertsWithReentrancy(MigrationFuzzParams memory p) public {
        MockReentrantFallbackMigrationRecipient recipient =
            new MockReentrantFallbackMigrationRecipient(ILBPStrategy(address(strategy)));

        LiquidityAllocationBracket[] memory brackets = _boundBrackets(p.bpParams);
        (MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock,) = _boundMigratorParams(p);
        mp.leftoverRecipient = address(recipient);

        // Currency mismatch routes to tier-2's CurrencyMismatch release, which transfers ETH to the recipient.
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
        brackets[0] = LiquidityAllocationBracket({lowerThreshold: 0, rate: 1e7});

        PositionDefinition[] memory defs = new PositionDefinition[](1);
        defs[0] = PositionDefinition({offsetLower: TickMath.MIN_TICK, offsetUpper: TickMath.MAX_TICK, weight: 1e7});

        mp = MigratorParameters({
            migrationBlock: uint64(block.number + 1),
            poolLPFee: 3000,
            poolTickSpacing: 60,
            supplyForLP: 100 ether,
            leftoverRecipient: leftoverRecipient,
            lpPositionRecipient: lpPositionRecipient,
            hook: address(0),
            token: address(0),
            currency: address(0),
            positionDefinitions: abi.encode(defs),
            lpAllocationSchedule: new bytes(0)
        });
        totalSupply = mp.supplyForLP + 10 ether;
        lbpParams = LBPInitializationParams({
            initialPriceX96: uint160(1 << 96), tokensSold: 1 ether, currencyRaised: 100 ether
        });
    }

    function _nativePoolKey(address token, uint24 fee, int24 tickSpacing, address hook)
        private
        pure
        returns (PoolKey memory)
    {
        Currency c0 = Currency.wrap(address(0));
        Currency c1 = Currency.wrap(token);
        if (uint160(address(0)) > uint160(token)) {
            (c0, c1) = (c1, c0);
        }
        return PoolKey({currency0: c0, currency1: c1, fee: fee, tickSpacing: tickSpacing, hooks: IHooks(hook)});
    }
}
