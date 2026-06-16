// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LBPStrategyTestBase} from "./base/LBPStrategyTestBase.sol";
import {ILBPStrategy} from "../../../src/interfaces/ILBPStrategy.sol";
import {ILBPInitializer, LBPInitializationParams} from "../../../src/interfaces/ILBPInitializer.sol";
import {MockLBPInitializer} from "test/mocks/MockLBPInitializer.sol";
import {MockReentrantInitializer} from "test/mocks/MockReentrantInitializer.sol";
import {MockReentrantMigrateRecipient} from "test/mocks/MockReentrantMigrateRecipient.sol";
import {MockRejectEth} from "test/mocks/MockRejectEth.sol";
import {MockNativeDonationHook} from "test/mocks/MockNativeDonationHook.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PositionDefinition} from "../../../src/types/PositionPlannerTypes.sol";
import {
    MigratorParams,
    MigratorParameters,
    PoolParameters,
    LiquidityAllocationBracket
} from "src/libraries/MigratorParams.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {Vm} from "forge-std/Vm.sol";

contract LBPStrategy_Migrate_Test is LBPStrategyTestBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    function test_emitsCurrencySwept(MigrationFuzzParams memory p) public {
        (MockLBPInitializer initializer,) = _setupForMigration(p);

        // Check indexed param (recipient); amount varies by fuzz inputs so left unchecked.
        vm.expectEmit(true, false, false, false, address(strategy));
        emit ILBPStrategy.CurrencySwept(recipient, 0);
        strategy.migrate(ILBPInitializer(address(initializer)));
    }

    function test_emitsTokensSwept(MigrationFuzzParams memory p) public {
        // Construct a setup where reservedTokenAmountForLP exceeds what the LP plan can consume, so remainingToken > 0
        // and the TokensSwept event fires. A narrow range with tiny currencyRaised ensures the currency
        // side caps the LP early, leaving most of reservedTokenAmountForLP unused.
        uint128 maxV4Delta = uint128(type(int128).max);

        LiquidityAllocationBracket[] memory bp = new LiquidityAllocationBracket[](1);
        bp[0] = LiquidityAllocationBracket({lowerThreshold: 0, rate: MigratorParams.MAX_BRACKET_RATE});

        p.poolParameters.tickSpacing = 1;
        p.auctionSupply = 1;
        p.initialPriceX96 = uint160(1 << 96);

        (MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock, uint128 auctionSupply) =
            _boundMigratorParams(p);
        mp.reservedTokenAmountForLP = maxV4Delta;
        totalSupply = mp.reservedTokenAmountForLP + auctionSupply;
        p.tokensSold = uint128(bound(p.tokensSold, 1, auctionSupply));

        PositionDefinition[] memory defs = new PositionDefinition[](1);
        defs[0] = PositionDefinition({
            offsetLower: -1, offsetUpper: 1, weight: 1e7, overridePositionRecipient: positionRecipient
        });
        mp.positionDefinitions = abi.encode(defs);

        LBPInitializationParams memory lbpParams = LBPInitializationParams({
            initialPriceX96: p.initialPriceX96, tokensSold: p.tokensSold, currencyRaised: maxV4Delta
        });
        (MockLBPInitializer initializer,) = _initializeWith(mp, totalSupply, endBlock, bp, address(0), lbpParams);

        vm.deal(address(initializer), maxV4Delta);
        vm.roll(mp.migrationBlock);
        vm.mockCall(address(POSITION_MANAGER), abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector), "");

        vm.expectEmit(true, false, false, false, address(strategy));
        emit ILBPStrategy.TokensSwept(recipient, 0);
        strategy.migrate(ILBPInitializer(address(initializer)));
    }

    function test_emitsMigrated(MigrationFuzzParams memory p) public {
        (MockLBPInitializer initializer,) = _setupForMigration(p);

        // Check indexed initializer (topic1); key and sqrtPriceX96 are derived from fuzz inputs.
        vm.expectEmit(true, false, false, false, address(strategy));
        emit ILBPStrategy.Migrated(
            ILBPInitializer(address(initializer)),
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(0)), 0, 0, IHooks(address(0))),
            0,
            bytes("")
        );
        strategy.migrate(ILBPInitializer(address(initializer)));
    }

    function test_migratedEventIncludesPositionPlan(MigrationFuzzParams memory p) public {
        (MockLBPInitializer initializer,) = _setupForMigration(p);

        bytes32 migratedTopic = keccak256("Migrated(address,(address,address,uint24,int24,address),uint160,bytes)");

        vm.recordLogs();
        strategy.migrate(ILBPInitializer(address(initializer)));
        Vm.Log[] memory entries = vm.getRecordedLogs();

        bytes memory emittedPlan;
        for (uint256 i; i < entries.length; i++) {
            if (entries[i].emitter == address(strategy) && entries[i].topics[0] == migratedTopic) {
                (, emittedPlan) = abi.decode(entries[i].data, (uint160, bytes));
                break;
            }
        }

        assertGt(emittedPlan.length, 0);
    }

    function test_currencyAmountCappedAtInt128Max(MigrationFuzzParams memory p, uint256 _hugeRaise) public {
        // Use a single bracket with rate >= 50% so minRaise stays in a practical range for vm.deal
        uint24 rate =
            uint24(bound(p.bpParams.rate0, MigratorParams.MAX_BRACKET_RATE / 2, MigratorParams.MAX_BRACKET_RATE));
        LiquidityAllocationBracket[] memory bp = new LiquidityAllocationBracket[](1);
        bp[0] = LiquidityAllocationBracket({lowerThreshold: 0, rate: rate});

        // Bound so that hugeRaise * rate / MAX_BRACKET_RATE > int128.max (triggers the cap).
        // _calculateCurrencyAmountForLp does currencyRaised * rate, so cap hugeRaise to avoid that overflow.
        uint256 minRaise = uint256(uint128(type(int128).max)) * MigratorParams.MAX_BRACKET_RATE / rate + 1;
        uint256 hugeRaise = bound(_hugeRaise, minRaise, type(uint256).max / rate);

        (MockLBPInitializer initializer, MockERC20 token) = _setupForMigrationWithSchedule(p, bp, hugeRaise);

        uint256 recipientBalBefore = recipient.balance;
        uint256 poolManagerBalBefore = address(POOL_MANAGER).balance;

        // Migrate — should not revert; currency amount gets capped at int128.max for the planner
        strategy.migrate(ILBPInitializer(address(initializer)));

        uint256 toRecipient = recipient.balance - recipientBalBefore;
        uint256 toPool = address(POOL_MANAGER).balance - poolManagerBalBefore;

        // No protocol fee is configured, so all raised currency is either deposited into the pool or swept
        assertEq(toRecipient + toPool, hugeRaise);
        // The pool can never consume more than the int128.max cap (excess is swept to recipient)
        assertLe(toPool, uint128(type(int128).max));

        // Strategy should be empty
        assertEq(address(strategy).balance, 0);
        assertEq(token.balanceOf(address(strategy)), 0);
    }

    function test_fuzz_recoversFundsWhenPositionManagerReverts_nativeCurrency(MigrationFuzzParams memory p) public {
        (MockLBPInitializer initializer, MockERC20 token) = _setupForMigration(p);
        MigratorParameters memory mp = strategy.initializers(ILBPInitializer(address(initializer)));
        uint256 raised = initializer.lbpInitializationParams().currencyRaised;

        uint256 recipientCurrencyBefore = mp.recipient.balance;
        uint256 recipientTokenBefore = token.balanceOf(mp.recipient);

        vm.mockCallRevert(
            address(POSITION_MANAGER),
            abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector),
            "POSITION_MANAGER_REVERT"
        );

        vm.expectEmit(true, true, false, true, address(strategy));
        emit ILBPStrategy.FundsRecovered(
            ILBPInitializer(address(initializer)), mp.recipient, mp.reservedTokenAmountForLP
        );
        vm.expectEmit(true, false, false, true, address(strategy));
        emit ILBPStrategy.MigrationFailed(ILBPInitializer(address(initializer)), bytes("POSITION_MANAGER_REVERT"));
        strategy.migrate(ILBPInitializer(address(initializer)));

        assertEq(mp.recipient.balance, recipientCurrencyBefore + raised);
        assertEq(token.balanceOf(mp.recipient), recipientTokenBefore + mp.reservedTokenAmountForLP);
        assertEq(_registeredFor(ILBPInitializer(address(initializer))), address(0));
        assertEq(address(initializer).balance, 0);
        assertEq(address(strategy).balance, 0);
        assertEq(token.balanceOf(address(strategy)), 0);
    }

    function test_fuzz_migrationForceSendsLeftoverToEthRejectingRecipient_nativeCurrency(MigrationFuzzParams memory p)
        public
    {
        (MockLBPInitializer initializer,) = _setupForMigration(p);
        MigratorParameters memory mp = strategy.initializers(ILBPInitializer(address(initializer)));

        // Funds recipient reverts on receiving ETH. A plain transfer of the leftover would brick tryMigrate
        // and silently downgrade migration to a recovery; the success path must still complete via force-send.
        vm.etch(mp.recipient, type(MockRejectEth).runtimeCode);
        uint256 recipientBalBefore = mp.recipient.balance;

        // Migration must succeed (emit Migrated), not fall back to recovery (FundsRecovered).
        vm.expectEmit(true, false, false, false, address(strategy));
        emit ILBPStrategy.Migrated(
            ILBPInitializer(address(initializer)),
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(0)), 0, 0, IHooks(address(0))),
            0,
            bytes("")
        );
        strategy.migrate(ILBPInitializer(address(initializer)));

        // The non-LP portion of the raise is force-sent to the recipient despite its reverting receive().
        assertGt(mp.recipient.balance, recipientBalBefore);
        assertEq(address(strategy).balance, 0);
    }

    function test_fuzz_recoveryForceSendsToEthRejectingRecipient_nativeCurrency(MigrationFuzzParams memory p) public {
        (MockLBPInitializer initializer, MockERC20 token) = _setupForMigration(p);
        MigratorParameters memory mp = strategy.initializers(ILBPInitializer(address(initializer)));
        uint256 raised = initializer.lbpInitializationParams().currencyRaised;

        // Make the funds recipient a contract that reverts on receiving ETH. A plain `currency.transfer`
        // in the recovery leg would revert and brick the whole migrate() (recovery never completes).
        vm.etch(mp.recipient, type(MockRejectEth).runtimeCode);
        uint256 recipientCurrencyBefore = mp.recipient.balance;
        uint256 recipientTokenBefore = token.balanceOf(mp.recipient);

        vm.mockCallRevert(
            address(POSITION_MANAGER),
            abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector),
            "POSITION_MANAGER_REVERT"
        );

        strategy.migrate(ILBPInitializer(address(initializer)));

        // Force-send still delivers the recovered currency despite the recipient's reverting receive().
        assertEq(mp.recipient.balance, recipientCurrencyBefore + raised);
        assertEq(token.balanceOf(mp.recipient), recipientTokenBefore + mp.reservedTokenAmountForLP);
        assertEq(_registeredFor(ILBPInitializer(address(initializer))), address(0));
        assertEq(address(strategy).balance, 0);
        assertEq(token.balanceOf(address(strategy)), 0);
    }

    /// @notice Nonzero native dust returned by the plan's closing TAKE_PAIR is captured by the strategy
    /// (the modifyLiquidities caller) and forwarded to the recipient. The strategy must end empty, and
    /// recipient + pool must net the full raise plus the donation. A donating hook drives the dust because
    /// the standard plan settles exactly and leaves zero POSM dust, so this return path is otherwise unexercised.
    function test_migrate_posmNativeDust_returnedToStrategy_andForwardedToRecipient() public {
        address dustRecipient = makeAddr("dustRecipient");
        MockNativeDonationHook hook = _deployDonationHook(1 ether);

        // 50% of the raise goes to LP, leaving non-LP leftover; the single full-range position fires the
        // hook's afterAddLiquidity, which donates 1 ether of native currency to the strategy via TAKE_PAIR.
        LiquidityAllocationBracket[] memory bp = new LiquidityAllocationBracket[](1);
        bp[0] = LiquidityAllocationBracket({lowerThreshold: 0, rate: 5e6});
        PositionDefinition[] memory defs = new PositionDefinition[](1);
        defs[0] = PositionDefinition({
            offsetLower: TickMath.MIN_TICK,
            offsetUpper: TickMath.MAX_TICK,
            weight: 1e7,
            overridePositionRecipient: positionRecipient
        });
        MigratorParameters memory mp = MigratorParameters({
            token: address(0),
            currency: address(0),
            migrationBlock: uint64(block.number + 1),
            reservedTokenAmountForLP: 100 ether,
            recipient: dustRecipient,
            positionRecipient: positionRecipient,
            poolParameters: PoolParameters({fee: 3000, tickSpacing: 60, hook: address(hook)}),
            positionDefinitions: abi.encode(defs),
            lpAllocationSchedule: new bytes(0)
        });
        LBPInitializationParams memory lbpParams = LBPInitializationParams({
            initialPriceX96: uint160(1 << 96), tokensSold: 1 ether, currencyRaised: 100 ether
        });
        (MockLBPInitializer initializer,) =
            _initializeWith(mp, 110 ether, uint64(block.number), bp, address(0), lbpParams);
        vm.deal(address(initializer), 100 ether);
        vm.roll(mp.migrationBlock);

        uint256 recipientBalBefore = dustRecipient.balance;
        uint256 poolMgrBalBefore = address(POOL_MANAGER).balance;
        uint256 nextTokenIdBefore = POSITION_MANAGER.nextTokenId();

        strategy.migrate(ILBPInitializer(address(initializer)));

        uint256 recipientGain = dustRecipient.balance - recipientBalBefore;
        uint256 poolGain = address(POOL_MANAGER).balance - poolMgrBalBefore;

        // The hook fired and donated its entire balance into the plan.
        assertTrue(hook.donated(), "hook did not donate");
        assertEq(address(hook).balance, 0, "hook retained donation");
        // Migration succeeded (LP position minted), it did not silently downgrade to recovery.
        assertGt(POSITION_MANAGER.nextTokenId(), nextTokenIdBefore, "no LP position minted");
        assertGt(poolGain, 0, "pool received no liquidity");
        // Strategy keeps nothing: the dust it received from TAKE_PAIR was swept on to the recipient.
        assertEq(address(strategy).balance, 0, "strategy retained dust");
        // The recipient receives the non-LP leftover PLUS the TAKE_PAIR dust (the donation).
        assertEq(recipientGain, 100 ether - poolGain + 1 ether, "recipient missing leftover + dust");
        assertEq(recipientGain + poolGain, 100 ether + 1 ether, "native conservation broken");
    }

    /// @notice Nonzero native TAKE_PAIR dust combined with a recipient that reverts on plain ETH transfers.
    /// The dust is returned to the strategy and force-sent, so migration completes (LP minted) and the
    /// recipient still receives the dust, rather than the plan reverting and downgrading to recovery.
    function test_migrate_posmNativeDust_rejectingRecipient_doesNotBrickMigration() public {
        MockRejectEth rejecter = new MockRejectEth();
        MockNativeDonationHook hook = _deployDonationHook(1 ether);

        // 50% of the raise goes to LP, leaving non-LP leftover; the single full-range position fires the
        // hook's afterAddLiquidity, which donates 1 ether of native currency to the strategy via TAKE_PAIR.
        LiquidityAllocationBracket[] memory bp = new LiquidityAllocationBracket[](1);
        bp[0] = LiquidityAllocationBracket({lowerThreshold: 0, rate: 5e6});
        PositionDefinition[] memory defs = new PositionDefinition[](1);
        defs[0] = PositionDefinition({
            offsetLower: TickMath.MIN_TICK,
            offsetUpper: TickMath.MAX_TICK,
            weight: 1e7,
            overridePositionRecipient: positionRecipient
        });
        MigratorParameters memory mp = MigratorParameters({
            token: address(0),
            currency: address(0),
            migrationBlock: uint64(block.number + 1),
            reservedTokenAmountForLP: 100 ether,
            recipient: address(rejecter),
            positionRecipient: positionRecipient,
            poolParameters: PoolParameters({fee: 3000, tickSpacing: 60, hook: address(hook)}),
            positionDefinitions: abi.encode(defs),
            lpAllocationSchedule: new bytes(0)
        });
        LBPInitializationParams memory lbpParams = LBPInitializationParams({
            initialPriceX96: uint160(1 << 96), tokensSold: 1 ether, currencyRaised: 100 ether
        });
        (MockLBPInitializer initializer,) =
            _initializeWith(mp, 110 ether, uint64(block.number), bp, address(0), lbpParams);
        vm.deal(address(initializer), 100 ether);
        vm.roll(mp.migrationBlock);

        uint256 recipientBalBefore = address(rejecter).balance;
        uint256 poolMgrBalBefore = address(POOL_MANAGER).balance;
        uint256 nextTokenIdBefore = POSITION_MANAGER.nextTokenId();

        strategy.migrate(ILBPInitializer(address(initializer)));

        uint256 recipientGain = address(rejecter).balance - recipientBalBefore;
        uint256 poolGain = address(POOL_MANAGER).balance - poolMgrBalBefore;

        // Migration completed via force-send rather than falling back to recovery.
        assertGt(POSITION_MANAGER.nextTokenId(), nextTokenIdBefore, "no LP position minted (recovered instead)");
        assertGt(poolGain, 0, "pool received no liquidity (recovered instead)");
        assertTrue(hook.donated(), "hook did not donate");
        assertEq(address(strategy).balance, 0, "strategy retained dust");
        // Force-send delivered the leftover + dust despite the recipient's reverting receive().
        assertEq(recipientGain, 100 ether - poolGain + 1 ether, "dust not force-sent to rejecting recipient");
        assertEq(recipientGain + poolGain, 100 ether + 1 ether, "native conservation broken");
    }

    function test_fuzz_recoversFundsWhenPositionManagerReverts_erc20Currency(MigrationFuzzParams memory p) public {
        MockERC20 currencyToken = new MockERC20("Currency", "CUR", type(uint128).max, address(this));

        LiquidityAllocationBracket[] memory bp = _boundBrackets(p.bpParams);
        p.currencyRaised = _boundCurrencyRaised(p.currencyRaised, bp);
        (MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock, uint128 auctionSupply) =
            _boundMigratorParams(p);
        p.initialPriceX96 = _boundInitialPriceX96(p.initialPriceX96);
        p.tokensSold = uint128(bound(p.tokensSold, 1, auctionSupply));

        LBPInitializationParams memory lbpParams = LBPInitializationParams({
            initialPriceX96: p.initialPriceX96, tokensSold: p.tokensSold, currencyRaised: p.currencyRaised
        });
        (MockLBPInitializer initializer, MockERC20 token) =
            _initializeWith(mp, totalSupply, endBlock, bp, address(currencyToken), lbpParams);

        deal(address(currencyToken), address(initializer), p.currencyRaised);
        vm.roll(mp.migrationBlock);

        uint256 recipientCurrencyBefore = currencyToken.balanceOf(mp.recipient);
        uint256 recipientTokenBefore = token.balanceOf(mp.recipient);

        vm.mockCallRevert(
            address(POSITION_MANAGER),
            abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector),
            "POSITION_MANAGER_REVERT"
        );

        vm.expectEmit(true, true, false, true, address(strategy));
        emit ILBPStrategy.FundsRecovered(
            ILBPInitializer(address(initializer)), mp.recipient, mp.reservedTokenAmountForLP
        );
        vm.expectEmit(true, false, false, true, address(strategy));
        emit ILBPStrategy.MigrationFailed(ILBPInitializer(address(initializer)), bytes("POSITION_MANAGER_REVERT"));
        strategy.migrate(ILBPInitializer(address(initializer)));

        assertEq(currencyToken.balanceOf(mp.recipient), recipientCurrencyBefore + p.currencyRaised);
        assertEq(token.balanceOf(mp.recipient), recipientTokenBefore + mp.reservedTokenAmountForLP);
        assertEq(_registeredFor(ILBPInitializer(address(initializer))), address(0));
        assertEq(currencyToken.balanceOf(address(initializer)), 0);
        assertEq(currencyToken.balanceOf(address(strategy)), 0);
        assertEq(token.balanceOf(address(strategy)), 0);
    }

    function test_skippedPositionBudgetsAreSweptToFundsRecipient(MigrationFuzzParams memory p) public {
        uint128 maxV4Delta = uint128(type(int128).max);

        // Single bracket at 100% rate
        LiquidityAllocationBracket[] memory bp = new LiquidityAllocationBracket[](1);
        bp[0] = LiquidityAllocationBracket({lowerThreshold: 0, rate: MigratorParams.MAX_BRACKET_RATE});

        p.poolParameters.tickSpacing = 1;
        p.auctionSupply = 1;
        p.initialPriceX96 = uint160(1 << 96);

        (MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock, uint128 auctionSupply) =
            _boundMigratorParams(p);
        mp.reservedTokenAmountForLP = maxV4Delta;
        totalSupply = mp.reservedTokenAmountForLP + auctionSupply;
        p.tokensSold = uint128(bound(p.tokensSold, 1, auctionSupply));

        PositionDefinition[] memory defs = new PositionDefinition[](1);
        defs[0] = PositionDefinition({
            offsetLower: -1, offsetUpper: 1, weight: 1e7, overridePositionRecipient: positionRecipient
        });
        mp.positionDefinitions = abi.encode(defs);

        LBPInitializationParams memory lbpParams = LBPInitializationParams({
            initialPriceX96: p.initialPriceX96, tokensSold: p.tokensSold, currencyRaised: maxV4Delta
        });
        (MockLBPInitializer initializer, MockERC20 token) =
            _initializeWith(mp, totalSupply, endBlock, bp, address(0), lbpParams);

        vm.deal(address(initializer), maxV4Delta);
        vm.roll(mp.migrationBlock);

        uint256 recipientBalBefore = recipient.balance;
        uint256 recipientTokenBalBefore = token.balanceOf(recipient);
        uint256 poolManagerBalBefore = address(POOL_MANAGER).balance;
        uint256 poolManagerTokenBalBefore = token.balanceOf(address(POOL_MANAGER));

        strategy.migrate(ILBPInitializer(address(initializer)));

        // No protocol fee is configured, so all raised currency is either deposited into the pool or swept
        assertEq(
            (recipient.balance - recipientBalBefore) + (address(POOL_MANAGER).balance - poolManagerBalBefore),
            maxV4Delta
        );
        // Only reservedTokenAmountForLP is distributed by the strategy; unsold auction tokens stay in the initializer.
        assertEq(
            (token.balanceOf(recipient) - recipientTokenBalBefore)
                + (token.balanceOf(address(POOL_MANAGER)) - poolManagerTokenBalBefore),
            mp.reservedTokenAmountForLP
        );
        assertEq(address(strategy).balance, 0);
        assertEq(token.balanceOf(address(strategy)), 0);
        assertEq(token.balanceOf(address(initializer)), auctionSupply);
    }

    function test_noHookUsesStrategyHookWhenRawPoolExists(MigrationFuzzParams memory p) public {
        LiquidityAllocationBracket[] memory bp = _boundBrackets(p.bpParams);
        (MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock, uint128 auctionSupply) =
            _boundMigratorParams(p);
        p.currencyRaised = _boundCurrencyRaised(p.currencyRaised, bp);
        p.initialPriceX96 = _boundInitialPriceX96(p.initialPriceX96);
        p.tokensSold = uint128(bound(p.tokensSold, 1, auctionSupply));

        LBPInitializationParams memory lbpParams = LBPInitializationParams({
            initialPriceX96: p.initialPriceX96, tokensSold: p.tokensSold, currencyRaised: p.currencyRaised
        });
        (MockLBPInitializer initializer, MockERC20 token) =
            _initializeWith(mp, totalSupply, endBlock, bp, address(0), lbpParams);
        vm.deal(address(initializer), p.currencyRaised);
        vm.roll(mp.migrationBlock);
        vm.mockCall(address(POSITION_MANAGER), abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector), "");

        PoolKey memory rawKey =
            _nativePoolKey(address(token), mp.poolParameters.fee, mp.poolParameters.tickSpacing, address(0));
        PoolKey memory strategyKey =
            _nativePoolKey(address(token), mp.poolParameters.fee, mp.poolParameters.tickSpacing, address(strategy));

        (uint160 rawSqrtPrice,,,) = POOL_MANAGER.getSlot0(rawKey.toId());
        (uint160 strategySqrtPrice,,,) = POOL_MANAGER.getSlot0(strategyKey.toId());
        assertEq(rawSqrtPrice, 0);
        assertEq(strategySqrtPrice, 0);

        POOL_MANAGER.initialize(rawKey, TickMath.MIN_SQRT_PRICE + 1);
        (rawSqrtPrice,,,) = POOL_MANAGER.getSlot0(rawKey.toId());
        assertGt(rawSqrtPrice, 0);

        vm.expectEmit(false, false, false, false);
        emit ILBPStrategy.Migrated(ILBPInitializer(address(initializer)), strategyKey, 0, bytes(""));
        strategy.migrate(ILBPInitializer(address(initializer)));

        (uint160 rawSqrtPriceAfter,,,) = POOL_MANAGER.getSlot0(rawKey.toId());
        (strategySqrtPrice,,,) = POOL_MANAGER.getSlot0(strategyKey.toId());
        assertEq(rawSqrtPriceAfter, rawSqrtPrice);
        assertGt(strategySqrtPrice, 0);
        assertEq(address(strategyKey.hooks), address(strategy));
        // The reservation on the registered (raw) key is cleared after the fallback migration.
        assertEq(_registeredFor(ILBPInitializer(address(initializer))), address(0));
    }

    /// @notice After a failed migration recovers funds, the reservation is cleared, so the initializer
    /// cannot be re-migrated (replay protection on the recovery path).
    function test_fuzz_cannotReMigrateAfterRecovery(MigrationFuzzParams memory p) public {
        (MockLBPInitializer initializer,) = _setupForMigration(p);

        vm.mockCallRevert(
            address(POSITION_MANAGER),
            abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector),
            "POSITION_MANAGER_REVERT"
        );
        strategy.migrate(ILBPInitializer(address(initializer)));
        assertEq(_registeredFor(ILBPInitializer(address(initializer))), address(0));

        // Reservation cleared on the registered key → a second migrate reverts InitializerNotRegistered.
        vm.expectRevert(
            abi.encodeWithSelector(
                ILBPStrategy.InitializerNotRegistered.selector, ILBPInitializer(address(initializer))
            )
        );
        strategy.migrate(ILBPInitializer(address(initializer)));
    }

    /// @notice An initializer that reenters migrate from inside sweepCurrency is blocked by the
    /// reentrancy guard on migrate.
    function test_fuzz_reentrantMigrateSweepCurrency_revertsWithReentrancy(MigrationFuzzParams memory p) public {
        LiquidityAllocationBracket[] memory brackets = _boundBrackets(p.bpParams);
        p.currencyRaised = _boundCurrencyRaised(p.currencyRaised, brackets);
        (MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock, uint128 auctionSupply) =
            _boundMigratorParams(p);
        p.initialPriceX96 = _boundInitialPriceX96(p.initialPriceX96);
        p.tokensSold = uint128(bound(p.tokensSold, 1, auctionSupply));

        MockERC20 token = new MockERC20("T", "T", totalSupply, address(this));
        MockReentrantInitializer reentrant = new MockReentrantInitializer(
            address(token),
            address(0),
            totalSupply,
            tokensRecipient,
            address(strategy),
            0,
            endBlock,
            ILBPStrategy(strategy)
        );
        LBPInitializationParams memory lbpParams = LBPInitializationParams({
            initialPriceX96: p.initialPriceX96, tokensSold: p.tokensSold, currencyRaised: p.currencyRaised
        });
        reentrant.setLbpInitializationParams(lbpParams);
        factory.setOverrideInitializer(MockLBPInitializer(payable(address(reentrant))));

        token.approve(address(strategy), totalSupply);
        mp.token = address(token);
        bytes memory configData =
            _encodeConfigData(mp, brackets, _encodeMockInitializerParams(endBlock, address(0), lbpParams));
        strategy.initializeDistribution(address(token), totalSupply, configData, bytes32(0));

        vm.deal(address(reentrant), p.currencyRaised);
        vm.roll(mp.migrationBlock);

        strategy.migrate(ILBPInitializer(address(reentrant)));

        assertTrue(reentrant.reentered(), "inner reentrant call did not fire");
        assertEq(
            bytes4(reentrant.capturedRevertData()),
            ReentrancyGuardTransient.Reentrancy.selector,
            "expected inner reentrant migrate to revert with Reentrancy"
        );
    }

    /// @notice A malicious recipient that reenters migrate(self) from its receive() during
    function test_fuzz_reentrantMigrateRecipient_revertsWithReentrancy(MigrationFuzzParams memory p) public {
        MockReentrantMigrateRecipient recipient = new MockReentrantMigrateRecipient(ILBPStrategy(address(strategy)));

        LiquidityAllocationBracket[] memory brackets = _boundBrackets(p.bpParams);
        p.currencyRaised = _boundCurrencyRaised(p.currencyRaised, brackets);
        (MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock, uint128 auctionSupply) =
            _boundMigratorParams(p);
        p.initialPriceX96 = _boundInitialPriceX96(p.initialPriceX96);
        p.tokensSold = uint128(bound(p.tokensSold, 1, auctionSupply));

        // Override recipient with the malicious contract.
        mp.recipient = address(recipient);

        LBPInitializationParams memory lbpParams = LBPInitializationParams({
            initialPriceX96: p.initialPriceX96, tokensSold: p.tokensSold, currencyRaised: p.currencyRaised
        });
        (MockLBPInitializer initializer,) = _initializeWith(mp, totalSupply, endBlock, brackets, address(0), lbpParams);

        vm.deal(address(initializer), p.currencyRaised);
        recipient.setInitializer(ILBPInitializer(address(initializer)));

        vm.roll(mp.migrationBlock);
        strategy.migrate(ILBPInitializer(address(initializer)));

        assertTrue(recipient.reentered());
        assertEq(bytes4(recipient.capturedRevertData()), ReentrancyGuardTransient.Reentrancy.selector);
    }

    /// @notice Mines and deploys a donating InitializerHook authorized for the strategy, funded so it can
    /// settle its native donation during the migration plan.
    function _deployDonationHook(uint256 donationAmount) internal returns (MockNativeDonationHook hook) {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG
        );
        bytes memory args = abi.encode(POOL_MANAGER, address(strategy), donationAmount);
        (address hookAddr, bytes32 salt) =
            HookMiner.find(address(this), flags, type(MockNativeDonationHook).creationCode, args);

        hook = new MockNativeDonationHook{salt: salt}(POOL_MANAGER, address(strategy), donationAmount);
        assertEq(address(hook), hookAddr, "hook address mismatch");

        vm.deal(address(hook), donationAmount);
    }

    function _nativePoolKey(address token, uint24 fee, int24 tickSpacing, address hook)
        internal
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
