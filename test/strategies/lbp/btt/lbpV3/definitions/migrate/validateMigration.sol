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
/// ├── when initializer is unregistered (migrationBlock == 0)
/// │   └── it reverts with InitializerNotRegistered(initializer)
/// ├── when initializer was already consumed (reserves == 0, migrationBlock != 0)
/// │   ├── it reverts with InsufficientReserves(initializer)
/// │   └── it reverts with InsufficientReserves(initializer) before checking migrationBlock
/// ├── when block.number < migrationBlock
/// │   └── it reverts with MigrationNotYetAllowed
/// └── when block.number >= migrationBlock
///     ├── when currencySwept != currencyRaised
///     │   └── it recovers the initializer funds to leftoverRecipient
///     └── when currencySwept == currencyRaised
///         ├── it calls sweepCurrency on initializer
///         ├── it sweeps leftover currency to recipient
///         ├── it sweeps leftover tokens to recipient
///         ├── it emits CurrencySwept
///         ├── it emits TokensSwept
///         └── it emits Migrated
contract ValidateMigrationTest is LBPStrategyTestBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    function test_WhenInitializerIsInitializerNotRegistered(uint64 _currentBlock, uint128 _tokensSold) public {
        // it reverts with {InitializerNotRegistered}
        _currentBlock = uint64(bound(_currentBlock, 1, type(uint64).max));
        vm.roll(_currentBlock);

        _tokensSold = uint128(bound(_tokensSold, 1, uint128(1 << 100)));

        ILBPInitializer unregistered = ILBPInitializer(
            address(
                new MockLBPInitializer(address(1), address(0), _tokensSold, address(strategy), address(strategy), 0, 0)
            )
        );

        // InitializerNotRegistered initializers have no params stored — migrationBlock == 0 distinguishes them
        // from initializers that were registered and then consumed.
        assertEq(strategy.initializers(unregistered).migrationBlock, 0);

        vm.expectRevert(abi.encodeWithSelector(ILBPStrategy.InitializerNotRegistered.selector, unregistered));
        strategy.migrate(unregistered);
    }

    function test_WhenInitializerWasInsufficientReserves(MigrationFuzzParams memory p) public {
        // it reverts with {InsufficientReserves}
        (MockLBPInitializer initializer,) = _setupForMigration(p);
        strategy.migrate(ILBPInitializer(address(initializer)));

        // After the first migrate, reserves are zeroed but migrationBlock remains nonzero —
        // so the second call hits the InsufficientReserves branch, not InitializerNotRegistered.
        assertEq(strategy.reserves(ILBPInitializer(address(initializer))), 0);
        assertGt(strategy.initializers(ILBPInitializer(address(initializer))).migrationBlock, 0);

        vm.expectRevert(
            abi.encodeWithSelector(ILBPStrategy.InsufficientReserves.selector, ILBPInitializer(address(initializer)))
        );
        strategy.migrate(ILBPInitializer(address(initializer)));
    }

    function test_WhenInitializerWasInsufficientReservesBeforeMigrationBlock(MigrationFuzzParams memory p) public {
        // it reverts with {InsufficientReserves} before checking migrationBlock
        (MockLBPInitializer initializer,) = _setupForMigration(p);
        strategy.migrate(ILBPInitializer(address(initializer)));
        uint256 migrationBlock = strategy.initializers(ILBPInitializer(address(initializer))).migrationBlock;

        // Roll back below migrationBlock to isolate onlyPendingMigrate's check order.
        vm.roll(migrationBlock - 1);

        vm.expectRevert(
            abi.encodeWithSelector(ILBPStrategy.InsufficientReserves.selector, ILBPInitializer(address(initializer)))
        );
        strategy.migrate(ILBPInitializer(address(initializer)));
    }

    function test_WhenBlockIsLTMigrationBlock(uint64 _currentBlock, MigrationFuzzParams memory p) public {
        // it reverts with {MigrationNotYetAllowed}
        (MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock,) = _boundMigratorParams(p);

        (MockLBPInitializer initializer,) = _initializeWith(mp, totalSupply, endBlock, _boundBrackets(p.bpParams));

        _currentBlock = uint64(bound(_currentBlock, 0, mp.migrationBlock - 1));
        vm.roll(_currentBlock);

        vm.expectRevert(
            abi.encodeWithSelector(ILBPStrategy.MigrationNotYetAllowed.selector, mp.migrationBlock, _currentBlock)
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
        // it recovers the initializer funds to leftoverRecipient
        (MockLBPInitializer initializer, MockERC20 token) = _setupForMigration(p);
        MigratorParameters memory mp = strategy.initializers(ILBPInitializer(address(initializer)));

        // After _setupForMigration, p.currencyRaised is bounded and both the initializer's
        // ETH balance and reported currencyRaised equal it. Force a mismatch by overriding
        // the initializer's balance. The failed migration should fall back to recovery.
        uint256 claimed = p.currencyRaised;
        actualAmount = bound(actualAmount, 1, uint256(uint128(type(int128).max)));
        vm.assume(actualAmount != claimed);

        vm.deal(address(initializer), actualAmount);

        uint256 recipientCurrencyBefore = mp.recipient.balance;
        uint256 recipientTokenBefore = token.balanceOf(mp.recipient);
        uint256 strategyTokenBefore = token.balanceOf(address(strategy));

        vm.expectEmit(true, true, false, true, address(strategy));
        emit ILBPStrategy.FundsRecovered(
            ILBPInitializer(address(initializer)), mp.recipient, mp.reservedTokenAmountForLP
        );
        strategy.migrate(ILBPInitializer(address(initializer)));

        assertEq(mp.recipient.balance, recipientCurrencyBefore + actualAmount);
        assertEq(token.balanceOf(mp.recipient), recipientTokenBefore + mp.reservedTokenAmountForLP);
        assertEq(token.balanceOf(address(strategy)), strategyTokenBefore - mp.reservedTokenAmountForLP);
        assertEq(strategy.reserves(ILBPInitializer(address(initializer))), 0);
        assertEq(address(initializer).balance, 0);
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

        uint256 fundsBefore = recipient.balance;
        uint256 poolBefore = address(POOL_MANAGER).balance;
        strategy.migrate(ILBPInitializer(address(initializer)));

        // Every wei raised reaches recipient or the pool manager — proves the sweep
        assertEq((recipient.balance - fundsBefore) + (address(POOL_MANAGER).balance - poolBefore), raised);
        assertEq(address(strategy).balance, 0);
    }

    function test_SweepsLeftoverTokensToFundsRecipient(MigrationFuzzParams memory p)
        public
        whenBlockIsGTEMigrationBlock
    {
        (MockLBPInitializer initializer, MockERC20 token) = _setupForMigration(p);
        uint256 reservedTokenAmountForLP =
            strategy.initializers(ILBPInitializer(address(initializer))).reservedTokenAmountForLP;
        uint256 unsoldInCca = token.balanceOf(address(initializer));

        uint256 fundsBefore = token.balanceOf(recipient);
        uint256 poolBefore = token.balanceOf(address(POOL_MANAGER));
        strategy.migrate(ILBPInitializer(address(initializer)));

        // reservedTokenAmountForLP is the only portion the strategy handles; it lands in
        // recipient or the pool manager. Unsold auction tokens stay in the initializer for the
        // tokensRecipient to claim separately.
        assertEq(
            (token.balanceOf(recipient) - fundsBefore) + (token.balanceOf(address(POOL_MANAGER)) - poolBefore),
            reservedTokenAmountForLP
        );
        assertEq(token.balanceOf(address(strategy)), 0);
        // The initializer's unsold balance is untouched by migrate.
        assertEq(token.balanceOf(address(initializer)), unsoldInCca);
    }

    function test_WhenHooklessPoolAlreadyExists_UsesStrategyAsHook() public whenBlockIsGTEMigrationBlock {
        (MockLBPInitializer initializer, MockERC20 token, MigratorParameters memory mp) =
            _setupKnownGoodMigration(100 ether, 10 ether, 100 ether);
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
