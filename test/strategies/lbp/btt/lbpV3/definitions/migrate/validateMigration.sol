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
/// ├── when block.number < migrationBlock
/// │   └── it reverts with MigrationNotAllowed
/// └── when block.number >= migrationBlock
///     ├── when identifier is bytes32(0) (unknown initializer)
///     │   └── it reverts with InvalidMigrationParameters
///     ├── when migrationParams hash != stored identifier
///     │   └── it reverts with InvalidMigrationParameters
///     └── when identifier matches
///         ├── when currencyRaised is 0 (after split)
///         │   └── it reverts with NoCurrencyRaised
///         └── when currencyRaised > 0
///             ├── it calls sweepCurrency on initializer
///             ├── it calls sweepUnsoldTokens on initializer
///             ├── it sweeps leftover currency to fundsRecipient
///             ├── it sweeps leftover tokens to fundsRecipient
///             ├── it emits CurrencySwept
///             ├── it emits TokensSwept
///             └── it emits Migrated
contract ValidateMigrationTest is LBPStrategyTestBase {
    function test_WhenBlockIsLTMigrationBlock(uint64 _currentBlock) public {
        (MockLBPInitializer initializer, ILBPStrategy.MigratorParameters memory mp) = _initializeWithDefaults();

        _currentBlock = uint64(bound(_currentBlock, 0, mp.migrationBlock - 1));
        vm.roll(_currentBlock);

        vm.expectRevert(
            abi.encodeWithSelector(ILBPStrategy.MigrationNotAllowed.selector, mp.migrationBlock, _currentBlock)
        );
        _migrateWithDefaults(initializer, mp);
    }

    modifier whenBlockIsGTEMigrationBlock() {
        _;
    }

    function test_WhenInitializerIsUnknown() public whenBlockIsGTEMigrationBlock {
        ILBPStrategy.MigratorParameters memory mp = _defaultMigratorParams();
        vm.roll(mp.migrationBlock);

        MockLBPInitializer fake =
            new MockLBPInitializer(address(token), address(0), 0, 0, address(strategy), address(strategy), 0, 0);

        vm.expectRevert(ILBPStrategy.InvalidMigrationParameters.selector);
        strategy.migrate(ILBPInitializer(address(fake)), mp, _defaultBreakpoints());
    }

    function test_WhenMigrationParamsDoNotMatch() public whenBlockIsGTEMigrationBlock {
        (MockLBPInitializer initializer, ILBPStrategy.MigratorParameters memory mp) = _initializeWithDefaults();
        vm.roll(mp.migrationBlock);

        mp.poolLPFee = 999;

        vm.expectRevert(ILBPStrategy.InvalidMigrationParameters.selector);
        _migrateWithDefaults(initializer, mp);
    }

    modifier whenIdentifierMatches() {
        _;
    }

    function test_WhenCurrencyRaisedIsZero() public whenBlockIsGTEMigrationBlock whenIdentifierMatches {
        (MockLBPInitializer initializer, ILBPStrategy.MigratorParameters memory mp) = _initializeWithDefaults();

        initializer.setLbpInitializationParams(
            LBPInitializationParams({initialPriceX96: FixedPoint96.Q96, tokensSold: 0, currencyRaised: 0})
        );
        token.transfer(address(initializer), DEFAULT_SUPPLY_FOR_LP + DEFAULT_CUSTODY_TOKENS);
        vm.roll(mp.migrationBlock);

        vm.expectRevert(ILBPStrategy.NoCurrencyRaised.selector);
        _migrateWithDefaults(initializer, mp);
    }

    modifier whenCurrencyRaisedIsGTZero() {
        _;
    }

    function test_CallsSweepOnInitializer()
        public
        whenBlockIsGTEMigrationBlock
        whenIdentifierMatches
        whenCurrencyRaisedIsGTZero
    {
        (MockLBPInitializer initializer, ILBPStrategy.MigratorParameters memory mp) =
            _setupForMigration(10e18, FixedPoint96.Q96);

        _migrateWithDefaults(initializer, mp);

        assertTrue(initializer.sweepCurrencyCalled());
        assertTrue(initializer.sweepUnsoldTokensCalled());
    }

    function test_SweepsLeftoverCurrencyToFundsRecipient()
        public
        whenBlockIsGTEMigrationBlock
        whenIdentifierMatches
        whenCurrencyRaisedIsGTZero
    {
        (MockLBPInitializer initializer, ILBPStrategy.MigratorParameters memory mp) =
            _setupForMigration(10e18, FixedPoint96.Q96);

        uint256 balBefore = fundsRecipient.balance;
        _migrateWithDefaults(initializer, mp);
        assertGe(fundsRecipient.balance, balBefore);
    }

    function test_SweepsLeftoverTokensToFundsRecipient()
        public
        whenBlockIsGTEMigrationBlock
        whenIdentifierMatches
        whenCurrencyRaisedIsGTZero
    {
        (MockLBPInitializer initializer, ILBPStrategy.MigratorParameters memory mp) =
            _setupForMigration(10e18, FixedPoint96.Q96);

        _migrateWithDefaults(initializer, mp);
        assertEq(token.balanceOf(address(strategy)), 0);
    }
}
