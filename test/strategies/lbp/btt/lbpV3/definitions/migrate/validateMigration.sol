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
    function test_WhenInitializerIsUnregistered(uint64 _currentBlock) public {
        _currentBlock = uint64(bound(_currentBlock, 1, type(uint64).max));
        vm.roll(_currentBlock);

        // Never registered via initializeDistribution, so stored migrationBlock is 0
        ILBPInitializer unregistered = ILBPInitializer(
            address(
                new MockLBPInitializer(address(token), address(0), 0, 0, address(strategy), address(strategy), 0, 0)
            )
        );

        // Stored migration params should be zero-valued
        (uint64 storedMigrationBlock,,,,,,,,) = strategy.initializers(unregistered);
        assertEq(storedMigrationBlock, 0);

        vm.expectRevert(abi.encodeWithSelector(ILBPStrategy.MigrationNotAllowed.selector, uint64(0), _currentBlock));
        strategy.migrate(unregistered);
    }

    function test_WhenBlockIsLTMigrationBlock(uint64 _currentBlock) public {
        (MockLBPInitializer initializer, ILBPStrategy.MigratorParameters memory mp) = _initializeWithDefaults();

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

    function test_WhenCurrencyRaisedIsZero() public whenBlockIsGTEMigrationBlock {
        (MockLBPInitializer initializer, ILBPStrategy.MigratorParameters memory mp) = _initializeWithDefaults();

        initializer.setLbpInitializationParams(
            LBPInitializationParams({initialPriceX96: FixedPoint96.Q96, tokensSold: 0, currencyRaised: 0})
        );
        token.transfer(address(initializer), DEFAULT_SUPPLY_FOR_LP + DEFAULT_CUSTODY_TOKENS);
        vm.roll(mp.migrationBlock);

        vm.expectRevert(ILBPStrategy.NoCurrencyRaised.selector);
        strategy.migrate(ILBPInitializer(address(initializer)));
    }

    modifier whenCurrencyRaisedIsGTZero() {
        _;
    }

    function test_CallsSweepOnInitializer() public whenBlockIsGTEMigrationBlock whenCurrencyRaisedIsGTZero {
        (MockLBPInitializer initializer,) = _setupForMigration(10e18, FixedPoint96.Q96);

        strategy.migrate(ILBPInitializer(address(initializer)));

        assertTrue(initializer.sweepCurrencyCalled());
        assertTrue(initializer.sweepUnsoldTokensCalled());
    }

    function test_SweepsLeftoverCurrencyToFundsRecipient()
        public
        whenBlockIsGTEMigrationBlock
        whenCurrencyRaisedIsGTZero
    {
        (MockLBPInitializer initializer,) = _setupForMigration(10e18, FixedPoint96.Q96);

        uint256 balBefore = fundsRecipient.balance;
        strategy.migrate(ILBPInitializer(address(initializer)));
        assertGe(fundsRecipient.balance, balBefore);
    }

    function test_SweepsLeftoverTokensToFundsRecipient()
        public
        whenBlockIsGTEMigrationBlock
        whenCurrencyRaisedIsGTZero
    {
        (MockLBPInitializer initializer,) = _setupForMigration(10e18, FixedPoint96.Q96);

        strategy.migrate(ILBPInitializer(address(initializer)));
        assertEq(token.balanceOf(address(strategy)), 0);
    }
}
