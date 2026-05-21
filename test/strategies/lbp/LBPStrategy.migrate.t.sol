// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LBPStrategyTestBase} from "./base/LBPStrategyTestBase.sol";
import {ILBPStrategy} from "src/interfaces/ILBPStrategy.sol";
import {ILBPInitializer, LBPInitializationParams} from "src/interfaces/ILBPInitializer.sol";
import {MockLBPInitializer} from "test/mocks/MockLBPInitializer.sol";
import {MockReentrantInitializer} from "test/mocks/MockReentrantInitializer.sol";
import {MockReentrantMigrateRecipient} from "test/mocks/MockReentrantMigrateRecipient.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PositionDefinition} from "src/types/PositionPlannerTypes.sol";
import {MigratorParams, MigratorParameters, LiquidityAllocationBracket} from "src/libraries/MigratorParams.sol";

contract LBPStrategy_Migrate_Test is LBPStrategyTestBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    function test_emitsCurrencySwept(MigrationFuzzParams memory p) public {
        (MockLBPInitializer initializer,) = _setupForMigration(p);

        // Check indexed param (leftoverRecipient); amount varies by fuzz inputs so left unchecked.
        vm.expectEmit(true, false, false, false, address(strategy));
        emit ILBPStrategy.CurrencySwept(leftoverRecipient, 0);
        strategy.migrate(ILBPInitializer(address(initializer)));
    }

    function test_emitsTokensSwept(MigrationFuzzParams memory p) public {
        // Construct a setup where supplyForLP exceeds what the LP plan can consume, so remainingToken > 0
        // and the TokensSwept event fires. A narrow range with tiny currencyRaised ensures the currency
        // side caps the LP early, leaving most of supplyForLP unused.
        uint128 maxV4Delta = uint128(type(int128).max);

        LiquidityAllocationBracket[] memory bp = new LiquidityAllocationBracket[](1);
        bp[0] = LiquidityAllocationBracket({lowerThreshold: 0, rate: MigratorParams.MAX_BRACKET_RATE});

        p.poolTickSpacing = 1;
        p.auctionSupply = 1;
        p.initialPriceX96 = uint160(1 << 96);

        (MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock, uint128 auctionSupply) =
            _boundMigratorParams(p);
        mp.supplyForLP = maxV4Delta;
        totalSupply = mp.supplyForLP + auctionSupply;
        p.tokensSold = uint128(bound(p.tokensSold, 1, auctionSupply));

        PositionDefinition[] memory defs = new PositionDefinition[](1);
        defs[0] = PositionDefinition({offsetLower: -1, offsetUpper: 1, weight: 1e7});
        mp.positionDefinitions = abi.encode(defs);

        LBPInitializationParams memory lbpParams = LBPInitializationParams({
            initialPriceX96: p.initialPriceX96, tokensSold: p.tokensSold, currencyRaised: maxV4Delta
        });
        (MockLBPInitializer initializer,) = _initializeWith(mp, totalSupply, endBlock, bp, address(0), lbpParams);

        vm.deal(address(initializer), maxV4Delta);
        vm.roll(mp.migrationBlock);
        vm.mockCall(address(POSITION_MANAGER), abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector), "");

        vm.expectEmit(true, false, false, false, address(strategy));
        emit ILBPStrategy.TokensSwept(leftoverRecipient, 0);
        strategy.migrate(ILBPInitializer(address(initializer)));
    }

    function test_emitsMigrated(MigrationFuzzParams memory p) public {
        (MockLBPInitializer initializer,) = _setupForMigration(p);

        // Check indexed initializer (topic1); key and sqrtPriceX96 are derived from fuzz inputs.
        vm.expectEmit(true, false, false, false, address(strategy));
        emit ILBPStrategy.Migrated(
            ILBPInitializer(address(initializer)),
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(0)), 0, 0, IHooks(address(0))),
            0
        );
        strategy.migrate(ILBPInitializer(address(initializer)));
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

        uint256 recipientBalBefore = leftoverRecipient.balance;
        uint256 poolManagerBalBefore = address(POOL_MANAGER).balance;

        // Migrate — should not revert; currency amount gets capped at int128.max for the planner
        strategy.migrate(ILBPInitializer(address(initializer)));

        uint256 toRecipient = leftoverRecipient.balance - recipientBalBefore;
        uint256 toPool = address(POOL_MANAGER).balance - poolManagerBalBefore;

        // No protocol fee is configured, so all raised currency is either deposited into the pool or swept
        assertEq(toRecipient + toPool, hugeRaise);
        // The pool can never consume more than the int128.max cap (excess is swept to leftoverRecipient)
        assertLe(toPool, uint128(type(int128).max));

        // Strategy should be empty
        assertEq(address(strategy).balance, 0);
        assertEq(token.balanceOf(address(strategy)), 0);
    }

    function test_skippedPositionBudgetsAreSweptToFundsRecipient(MigrationFuzzParams memory p) public {
        uint128 maxV4Delta = uint128(type(int128).max);

        // Single bracket at 100% rate
        LiquidityAllocationBracket[] memory bp = new LiquidityAllocationBracket[](1);
        bp[0] = LiquidityAllocationBracket({lowerThreshold: 0, rate: MigratorParams.MAX_BRACKET_RATE});

        p.poolTickSpacing = 1;
        p.auctionSupply = 1;
        p.initialPriceX96 = uint160(1 << 96);

        (MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock, uint128 auctionSupply) =
            _boundMigratorParams(p);
        mp.supplyForLP = maxV4Delta;
        totalSupply = mp.supplyForLP + auctionSupply;
        p.tokensSold = uint128(bound(p.tokensSold, 1, auctionSupply));

        PositionDefinition[] memory defs = new PositionDefinition[](1);
        defs[0] = PositionDefinition({offsetLower: -1, offsetUpper: 1, weight: 1e7});
        mp.positionDefinitions = abi.encode(defs);

        LBPInitializationParams memory lbpParams = LBPInitializationParams({
            initialPriceX96: p.initialPriceX96, tokensSold: p.tokensSold, currencyRaised: maxV4Delta
        });
        (MockLBPInitializer initializer, MockERC20 token) =
            _initializeWith(mp, totalSupply, endBlock, bp, address(0), lbpParams);

        vm.deal(address(initializer), maxV4Delta);
        vm.roll(mp.migrationBlock);

        uint256 recipientBalBefore = leftoverRecipient.balance;
        uint256 recipientTokenBalBefore = token.balanceOf(leftoverRecipient);
        uint256 poolManagerBalBefore = address(POOL_MANAGER).balance;
        uint256 poolManagerTokenBalBefore = token.balanceOf(address(POOL_MANAGER));

        strategy.migrate(ILBPInitializer(address(initializer)));

        // No protocol fee is configured, so all raised currency is either deposited into the pool or swept
        assertEq(
            (leftoverRecipient.balance - recipientBalBefore) + (address(POOL_MANAGER).balance - poolManagerBalBefore),
            maxV4Delta
        );
        // Only supplyForLP is distributed by the strategy; unsold auction tokens stay in the initializer.
        assertEq(
            (token.balanceOf(leftoverRecipient) - recipientTokenBalBefore)
                + (token.balanceOf(address(POOL_MANAGER)) - poolManagerTokenBalBefore),
            mp.supplyForLP
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

        PoolKey memory rawKey = _nativePoolKey(address(token), mp.poolLPFee, mp.poolTickSpacing, address(0));
        PoolKey memory strategyKey = _nativePoolKey(address(token), mp.poolLPFee, mp.poolTickSpacing, address(strategy));

        (uint160 rawSqrtPrice,,,) = POOL_MANAGER.getSlot0(rawKey.toId());
        (uint160 strategySqrtPrice,,,) = POOL_MANAGER.getSlot0(strategyKey.toId());
        assertEq(rawSqrtPrice, 0);
        assertEq(strategySqrtPrice, 0);

        POOL_MANAGER.initialize(rawKey, TickMath.MIN_SQRT_PRICE + 1);
        (rawSqrtPrice,,,) = POOL_MANAGER.getSlot0(rawKey.toId());
        assertGt(rawSqrtPrice, 0);

        vm.expectEmit(false, false, false, false);
        emit ILBPStrategy.Migrated(ILBPInitializer(address(initializer)), strategyKey, 0);
        strategy.migrate(ILBPInitializer(address(initializer)));

        (uint160 rawSqrtPriceAfter,,,) = POOL_MANAGER.getSlot0(rawKey.toId());
        (strategySqrtPrice,,,) = POOL_MANAGER.getSlot0(strategyKey.toId());
        assertEq(rawSqrtPriceAfter, rawSqrtPrice);
        assertGt(strategySqrtPrice, 0);
        assertEq(address(strategyKey.hooks), address(strategy));
    }

    /// @notice An initializer that reenters migrate from inside sweepCurrency hits
    /// AlreadyConsumed because reserves are zeroed at the top of migrate before any external call.
    function test_fuzz_reentrantMigrateSweepCurrency_revertsWithAlreadyConsumed(MigrationFuzzParams memory p) public {
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
            ILBPStrategy.AlreadyConsumed.selector,
            "expected inner reentrant migrate to revert with AlreadyConsumed"
        );
    }

    /// @notice A malicious leftoverRecipient that reenters migrate(self) from its receive() during
    /// the leftover-currency-transfer leg must hit AlreadyConsumed — reserves are zeroed at the top
    /// of migrate before any external interaction. Different reentry point than the sweepCurrency
    /// vector above.
    function test_fuzz_reentrantMigrateLeftoverRecipient_revertsWithAlreadyConsumed(MigrationFuzzParams memory p)
        public
    {
        MockReentrantMigrateRecipient recipient = new MockReentrantMigrateRecipient(ILBPStrategy(address(strategy)));

        LiquidityAllocationBracket[] memory brackets = _boundBrackets(p.bpParams);
        p.currencyRaised = _boundCurrencyRaised(p.currencyRaised, brackets);
        (MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock, uint128 auctionSupply) =
            _boundMigratorParams(p);
        p.initialPriceX96 = _boundInitialPriceX96(p.initialPriceX96);
        p.tokensSold = uint128(bound(p.tokensSold, 1, auctionSupply));

        // Override leftoverRecipient with the malicious contract.
        mp.leftoverRecipient = address(recipient);

        LBPInitializationParams memory lbpParams = LBPInitializationParams({
            initialPriceX96: p.initialPriceX96, tokensSold: p.tokensSold, currencyRaised: p.currencyRaised
        });
        (MockLBPInitializer initializer,) = _initializeWith(mp, totalSupply, endBlock, brackets, address(0), lbpParams);

        vm.deal(address(initializer), p.currencyRaised);
        recipient.setInitializer(ILBPInitializer(address(initializer)));

        vm.roll(mp.migrationBlock);
        strategy.migrate(ILBPInitializer(address(initializer)));

        assertTrue(recipient.reentered());
        assertEq(bytes4(recipient.capturedRevertData()), ILBPStrategy.AlreadyConsumed.selector);
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
