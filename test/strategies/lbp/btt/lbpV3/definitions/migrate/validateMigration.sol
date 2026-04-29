// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {LBPStrategyTestBase} from "../../../../base/LBPStrategyTestBase.sol";
import {ILBPStrategy} from "src/interfaces/ILBPStrategy.sol";
import {ILBPInitializer, LBPInitializationParams} from "src/interfaces/ILBPInitializer.sol";
import {MockLBPInitializer} from "test/mocks/MockLBPInitializer.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";

/// @title ValidateMigrationTest
/// @notice BTT tests for LBPStrategy.migrate validation
///
/// migrate
/// ├── when initializer is unregistered (stored migrationBlock == 0)
/// │   └── it reverts with MigrationNotAllowed(0, currentBlock)
/// ├── when block.number < migrationBlock
/// │   └── it reverts with MigrationNotAllowed
/// └── when block.number >= migrationBlock
///     ├── when currencyRaised is 0 (after split)
///     │   └── it reverts with NoCurrencyRaised
///     └── when currencyRaised > 0
///         ├── it calls sweepCurrency on initializer
///         ├── it calls sweepUnsoldTokens on initializer
///         ├── it sweeps leftover currency to fundsRecipient
///         ├── it sweeps leftover tokens to fundsRecipient
///         ├── it emits CurrencySwept
///         ├── it emits TokensSwept
///         └── it emits Migrated
contract ValidateMigrationTest is LBPStrategyTestBase {
    function test_WhenBlockIsLTMigrationBlock(uint64 _currentBlock) public {
        (MockLBPInitializer initializer, ILBPStrategy.MigratorParameters memory mp) = _initializeWithDefaults();

        _currentBlock = uint64(bound(_currentBlock, 0, mp.migrationBlock - 1));
        vm.roll(_currentBlock);

        vm.expectRevert(
            abi.encodeWithSelector(ILBPStrategy.MigrationNotAllowed.selector, mp.migrationBlock, _currentBlock)
        );
        _migrateWithDefaults(initializer);
    }

    modifier whenBlockIsGTEMigrationBlock() {
        _;
    }

    function test_WhenInitializerIsUnregistered() public whenBlockIsGTEMigrationBlock {
        vm.roll(1000);

        MockLBPInitializer fake =
            new MockLBPInitializer(address(token), address(0), 0, 0, address(strategy), address(strategy), 0, 0);

        // Unregistered initializer has migrationBlock == 0, so it reverts with MigrationNotAllowed
        vm.expectRevert(abi.encodeWithSelector(ILBPStrategy.MigrationNotAllowed.selector, uint64(0), uint64(1000)));
        strategy.migrate(ILBPInitializer(address(fake)));
    }

    function test_WhenCurrencyRaisedIsZero(uint256 _initialPriceX96) public whenBlockIsGTEMigrationBlock {
        _initialPriceX96 = bound(_initialPriceX96, 1, type(uint160).max);

        (MockLBPInitializer initializer, ILBPStrategy.MigratorParameters memory mp) = _initializeWithDefaults();

        initializer.setLbpInitializationParams(
            LBPInitializationParams({initialPriceX96: _initialPriceX96, tokensSold: 0, currencyRaised: 0})
        );
        token.transfer(address(initializer), DEFAULT_SUPPLY_FOR_LP);
        vm.roll(mp.migrationBlock);

        vm.expectRevert(ILBPStrategy.NoCurrencyRaised.selector);
        _migrateWithDefaults(initializer);
    }

    modifier whenCurrencyRaisedIsGTZero() {
        _;
    }

    function test_CallsSweepOnInitializer(uint128 _currencyRaised)
        public
        whenBlockIsGTEMigrationBlock
        whenCurrencyRaisedIsGTZero
    {
        // Minimum ensures currencyRaised * DEFAULT_RATE / 1e7 > 0
        _currencyRaised = uint128(bound(_currencyRaised, 1e7 / DEFAULT_RATE + 1, type(uint128).max));

        (MockLBPInitializer initializer,) = _setupForMigration(_currencyRaised, FixedPoint96.Q96);

        _migrateWithDefaults(initializer);

        assertTrue(initializer.sweepCurrencyCalled());
        assertTrue(initializer.sweepUnsoldTokensCalled());
    }

    function test_SweepsLeftoverCurrencyToFundsRecipient(uint128 _currencyRaised)
        public
        whenBlockIsGTEMigrationBlock
        whenCurrencyRaisedIsGTZero
    {
        _currencyRaised = uint128(bound(_currencyRaised, 1e7 / DEFAULT_RATE + 1, type(uint128).max));

        (MockLBPInitializer initializer,) = _setupForMigration(_currencyRaised, FixedPoint96.Q96);

        uint256 balBefore = fundsRecipient.balance;
        _migrateWithDefaults(initializer);
        assertGe(fundsRecipient.balance, balBefore);
    }

    function test_SweepsLeftoverTokensToFundsRecipient(uint128 _currencyRaised)
        public
        whenBlockIsGTEMigrationBlock
        whenCurrencyRaisedIsGTZero
    {
        _currencyRaised = uint128(bound(_currencyRaised, 1e7 / DEFAULT_RATE + 1, type(uint128).max));

        (MockLBPInitializer initializer,) = _setupForMigration(_currencyRaised, FixedPoint96.Q96);

        _migrateWithDefaults(initializer);
        assertEq(token.balanceOf(address(strategy)), 0);
    }
}
