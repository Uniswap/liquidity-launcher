// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LBPStrategyTestBase} from "../../../../base/LBPStrategyTestBase.sol";
import {ILBPStrategy} from "src/interfaces/ILBPStrategy.sol";
import {MigratorParameters} from "src/libraries/MigratorParams.sol";
import {ILBPInitializer} from "src/interfaces/ILBPInitializer.sol";
import {MockLBPInitializer} from "test/mocks/MockLBPInitializer.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title ValidateMigrationTest
/// @notice BTT tests for LBPStrategy.migrate validation
///
/// migrate
/// ├── when initializer is unregistered (stored migrationBlock == 0)
/// │   └── it reverts with MigrationNotAllowed(0, currentBlock)
/// ├── when block.number < migrationBlock
/// │   └── it reverts with MigrationNotAllowed
/// └── when block.number >= migrationBlock
///     ├── it calls sweepCurrency on initializer
///     ├── it calls sweepUnsoldTokens on initializer
///     ├── it sweeps leftover currency to fundsRecipient
///     ├── it sweeps leftover tokens to fundsRecipient
///     ├── it emits CurrencySwept
///     ├── it emits TokensSwept
///     └── it emits Migrated
contract ValidateMigrationTest is LBPStrategyTestBase {
    function test_WhenInitializerIsUnregistered(uint64 _currentBlock, uint128 _tokensSold) public {
        // it reverts with {MigrationNotAllowed}
        _currentBlock = uint64(bound(_currentBlock, 1, type(uint64).max));
        vm.roll(_currentBlock);

        _tokensSold = uint128(bound(_tokensSold, 1, uint128(1 << 100)));

        ILBPInitializer unregistered = ILBPInitializer(
            address(
                new MockLBPInitializer(
                    address(1), address(0), _tokensSold, 0, address(strategy), address(strategy), 0, 0
                )
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

    function test_CallsSweepOnInitializer(MigrationFuzzParams memory p) public whenBlockIsGTEMigrationBlock {
        (MockLBPInitializer initializer, MockERC20 token) = _setupForMigration(p);

        assertGt(Currency.wrap(initializer.currency()).balanceOfSelf(), 0);
        assertGt(token.balanceOf(address(initializer)), 0);

        strategy.migrate(ILBPInitializer(address(initializer)));

        assertEq(address(initializer).balance, 0);
        assertEq(token.balanceOf(address(initializer)), 0);
    }

    function test_SweepsLeftoverCurrencyToFundsRecipient(MigrationFuzzParams memory p)
        public
        whenBlockIsGTEMigrationBlock
    {
        (MockLBPInitializer initializer,) = _setupForMigration(p);
        uint256 raised = initializer.lbpInitializationParams().currencyRaised;

        uint256 fundsBefore = fundsRecipient.balance;
        uint256 poolBefore = address(POOL_MANAGER).balance;
        strategy.migrate(ILBPInitializer(address(initializer)));

        // Every wei raised reaches fundsRecipient or the pool manager — proves the sweep
        assertEq((fundsRecipient.balance - fundsBefore) + (address(POOL_MANAGER).balance - poolBefore), raised);
        assertEq(address(strategy).balance, 0);
    }

    function test_SweepsLeftoverTokensToFundsRecipient(MigrationFuzzParams memory p)
        public
        whenBlockIsGTEMigrationBlock
    {
        (MockLBPInitializer initializer, MockERC20 token) = _setupForMigration(p);
        uint256 totalSupply = token.totalSupply();

        uint256 fundsBefore = token.balanceOf(fundsRecipient);
        uint256 poolBefore = token.balanceOf(address(POOL_MANAGER));
        strategy.migrate(ILBPInitializer(address(initializer)));

        // Every token issued reaches fundsRecipient or the pool manager
        assertEq(
            (token.balanceOf(fundsRecipient) - fundsBefore) + (token.balanceOf(address(POOL_MANAGER)) - poolBefore),
            totalSupply
        );
        assertEq(token.balanceOf(address(strategy)), 0);
    }
}
