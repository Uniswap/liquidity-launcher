// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LBPStrategyTestBase} from "../../../../base/LBPStrategyTestBase.sol";
import {ILBPStrategy} from "src/interfaces/ILBPStrategy.sol";
import {MigratorParameters, LiquidityAllocationBracket} from "src/libraries/MigratorParams.sol";
import {ILBPInitializer, LBPInitializationParams} from "src/interfaces/ILBPInitializer.sol";
import {MockLBPInitializer} from "test/mocks/MockLBPInitializer.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

/// @title ValidateMigrationTest
/// @notice BTT tests for LBPStrategy.migrate validation
///
/// migrate
/// ├── when initializer is unregistered (stored migrationBlock == 0)
/// │   └── it reverts with MigrationNotAllowed(0, currentBlock)
/// ├── when block.number < migrationBlock
/// │   └── it reverts with MigrationNotAllowed
/// └── when block.number >= migrationBlock
///     ├── when currencySwept != currencyRaised
///     │   └── it reverts with CurrencyRaisedMismatch
///     └── when currencySwept == currencyRaised
///         ├── it calls sweepCurrency on initializer
///         ├── it sweeps leftover currency to leftoverRecipient
///         ├── it sweeps leftover tokens to leftoverRecipient
///         ├── it emits CurrencySwept
///         ├── it emits TokensSwept
///         └── it emits Migrated
contract ValidateMigrationTest is LBPStrategyTestBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    function test_WhenInitializerIsUnregistered(uint64 _currentBlock, uint128 _tokensSold) public {
        // it reverts with {MigrationNotAllowed}
        _currentBlock = uint64(bound(_currentBlock, 1, type(uint64).max));
        vm.roll(_currentBlock);

        _tokensSold = uint128(bound(_tokensSold, 1, uint128(1 << 100)));

        ILBPInitializer unregistered = ILBPInitializer(
            address(
                new MockLBPInitializer(address(1), address(0), _tokensSold, address(strategy), address(strategy), 0, 0)
            )
        );

        (MigratorParameters memory storedParams) = strategy.initializers(unregistered);
        assertEq(storedParams.migrationBlock, 0);

        vm.expectRevert(abi.encodeWithSelector(ILBPStrategy.MigrationNotAllowed.selector, uint64(0), _currentBlock));
        strategy.migrate(unregistered);
    }

    function test_WhenBlockIsLTMigrationBlock(uint64 _currentBlock, MigrationFuzzParams memory p) public {
        // it reverts with {MigrationNotAllowed}
        (MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock,) = _boundMigratorParams(p);

        (MockLBPInitializer initializer,) = _initializeWith(mp, totalSupply, endBlock, _boundBrackets(p.bpParams));

        _currentBlock = uint64(bound(_currentBlock, 0, mp.migrationBlock - 1));
        vm.roll(_currentBlock);

        vm.expectRevert(
            abi.encodeWithSelector(ILBPStrategy.MigrationNotAllowed.selector, mp.migrationBlock, _currentBlock)
        );
        strategy.migrate(ILBPInitializer(address(initializer)));
    }

    modifier whenBlockIsGTEMigrationBlock() {
        _;
    }

    function test_WhenCurrencySweptMismatchesCurrencyRaised(MigrationFuzzParams memory p, uint256 actualAmount)
        public
        whenBlockIsGTEMigrationBlock
    {
        // it reverts with {CurrencyRaisedMismatch}
        (MockLBPInitializer initializer,) = _setupForMigration(p);

        // After _setupForMigration, p.currencyRaised is bounded and both the initializer's
        // ETH balance and reported currencyRaised equal it. Force a mismatch by overriding
        // the initializer's balance.
        uint256 claimed = p.currencyRaised;
        actualAmount = bound(actualAmount, 0, uint256(uint128(type(int128).max)));
        vm.assume(actualAmount != claimed);

        vm.deal(address(initializer), actualAmount);

        vm.expectRevert(abi.encodeWithSelector(ILBPStrategy.CurrencyRaisedMismatch.selector, actualAmount, claimed));
        strategy.migrate(ILBPInitializer(address(initializer)));
    }

    function test_CallsSweepOnInitializer(MigrationFuzzParams memory p) public whenBlockIsGTEMigrationBlock {
        (MockLBPInitializer initializer, MockERC20 token) = _setupForMigration(p);

        assertGt(Currency.wrap(initializer.currency()).balanceOfSelf(), 0);
        uint256 tokensInInitializerBefore = token.balanceOf(address(initializer));
        assertGt(tokensInInitializerBefore, 0);

        strategy.migrate(ILBPInitializer(address(initializer)));

        // sweepCurrency drains the initializer's currency
        assertEq(address(initializer).balance, 0);
        // Unsold auction tokens stay in the initializer — they are claimed separately by the tokensRecipient
        assertEq(token.balanceOf(address(initializer)), tokensInInitializerBefore);
    }

    function test_SweepsLeftoverCurrencyToFundsRecipient(MigrationFuzzParams memory p)
        public
        whenBlockIsGTEMigrationBlock
    {
        (MockLBPInitializer initializer,) = _setupForMigration(p);
        uint256 raised = initializer.lbpInitializationParams().currencyRaised;

        uint256 fundsBefore = leftoverRecipient.balance;
        uint256 poolBefore = address(POOL_MANAGER).balance;
        strategy.migrate(ILBPInitializer(address(initializer)));

        // Every wei raised reaches leftoverRecipient or the pool manager — proves the sweep
        assertEq((leftoverRecipient.balance - fundsBefore) + (address(POOL_MANAGER).balance - poolBefore), raised);
        assertEq(address(strategy).balance, 0);
    }

    function test_SweepsLeftoverTokensToFundsRecipient(MigrationFuzzParams memory p)
        public
        whenBlockIsGTEMigrationBlock
    {
        (MockLBPInitializer initializer, MockERC20 token) = _setupForMigration(p);
        uint256 supplyForLP = strategy.initializers(ILBPInitializer(address(initializer))).supplyForLP;
        uint256 unsoldInCca = token.balanceOf(address(initializer));

        uint256 fundsBefore = token.balanceOf(leftoverRecipient);
        uint256 poolBefore = token.balanceOf(address(POOL_MANAGER));
        strategy.migrate(ILBPInitializer(address(initializer)));

        // The LP slice (supplyForLP) is the only token slice the strategy handles; it lands in
        // leftoverRecipient or the pool manager. Unsold auction tokens stay in the CCA for the
        // tokensRecipient to claim separately.
        assertEq(
            (token.balanceOf(leftoverRecipient) - fundsBefore) + (token.balanceOf(address(POOL_MANAGER)) - poolBefore),
            supplyForLP
        );
        assertEq(token.balanceOf(address(strategy)), 0);
        // The CCA's unsold balance is untouched by migrate.
        assertEq(token.balanceOf(address(initializer)), unsoldInCca);
    }

    function test_WhenHooklessPoolAlreadyExists_UsesStrategyAsHook(MigrationFuzzParams memory p)
        public
        whenBlockIsGTEMigrationBlock
    {
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
        auctionSupply;
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

        strategy.migrate(ILBPInitializer(address(initializer)));

        (uint160 rawSqrtPriceAfter,,,) = POOL_MANAGER.getSlot0(rawKey.toId());
        (strategySqrtPrice,,,) = POOL_MANAGER.getSlot0(strategyKey.toId());
        assertEq(rawSqrtPriceAfter, rawSqrtPrice);
        assertGt(strategySqrtPrice, 0);
        assertEq(address(strategyKey.hooks), address(strategy));
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
