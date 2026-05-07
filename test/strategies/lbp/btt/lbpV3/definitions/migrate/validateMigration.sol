// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {LBPStrategyTestBase} from "../../../../base/LBPStrategyTestBase.sol";
import {ILBPStrategy} from "src/interfaces/ILBPStrategy.sol";
import {ILBPInitializer, LBPInitializationParams} from "src/interfaces/ILBPInitializer.sol";
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

        (uint64 storedMigrationBlock,,,,,,,,) = strategy.initializers(unregistered);
        assertEq(storedMigrationBlock, 0);

        vm.expectRevert(abi.encodeWithSelector(ILBPStrategy.MigrationNotAllowed.selector, uint64(0), _currentBlock));
        strategy.migrate(unregistered);
    }

    function test_WhenBlockIsLTMigrationBlock(uint64 _currentBlock, FuzzParams memory p) public {
        // it reverts with {MigrationNotAllowed}
        (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock,) = _boundMigratorParams(p);

        (MockLBPInitializer initializer,) = _initializeWith(mp, totalSupply, endBlock);

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

    function test_WhenCurrencyRaisedIsZero(FuzzParams memory p) public whenBlockIsGTEMigrationBlock {
        // it skips LP creation and sweeps assets
        p.initialPriceX96 = _boundInitialPriceX96(p.initialPriceX96);

        (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock, uint128 auctionSupply) =
            _boundMigratorParams(p);
        p.tokensSold = uint128(bound(p.tokensSold, 0, auctionSupply));

        (MockLBPInitializer initializer, MockERC20 token) = _initializeWith(mp, totalSupply, endBlock);

        initializer.setLbpInitializationParams(
            LBPInitializationParams({initialPriceX96: p.initialPriceX96, tokensSold: p.tokensSold, currencyRaised: 0})
        );
        token.transfer(address(initializer), totalSupply);
        vm.roll(mp.migrationBlock);

        uint256 tokenBalBefore = token.balanceOf(fundsRecipient);
        strategy.migrate(ILBPInitializer(address(initializer)));

        assertEq(address(strategy).balance, 0);
        assertEq(token.balanceOf(address(strategy)), 0);
        assertGt(token.balanceOf(fundsRecipient), tokenBalBefore);
    }

    function test_WhenCurrencyRaisedRoundsToZero(FuzzParams memory p) public whenBlockIsGTEMigrationBlock {
        // it skips LP creation and sweeps assets
        p.initialPriceX96 = _boundInitialPriceX96(p.initialPriceX96);

        (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock, uint128 auctionSupply) =
            _boundMigratorParams(p);
        mp.currencySplitForLP = 1;
        p.tokensSold = uint128(bound(p.tokensSold, 0, auctionSupply));

        (MockLBPInitializer initializer, MockERC20 token) = _initializeWith(mp, totalSupply, endBlock);

        initializer.setLbpInitializationParams(
            LBPInitializationParams({initialPriceX96: p.initialPriceX96, tokensSold: p.tokensSold, currencyRaised: 1})
        );
        vm.deal(address(initializer), 1);
        token.transfer(address(initializer), totalSupply);
        vm.roll(mp.migrationBlock);

        uint256 balBefore = fundsRecipient.balance;
        strategy.migrate(ILBPInitializer(address(initializer)));

        assertEq(address(strategy).balance, 0);
        assertEq(fundsRecipient.balance - balBefore, 1);
    }

    modifier whenCurrencyRaisedIsGTZero() {
        _;
    }

    function test_CallsSweepOnInitializer(FuzzParams memory p)
        public
        whenBlockIsGTEMigrationBlock
        whenCurrencyRaisedIsGTZero
    {
        (MockLBPInitializer initializer, MockERC20 token) = _setupForMigration(p);

        assertGt(Currency.wrap(initializer.currency()).balanceOfSelf(), 0);
        assertGt(token.balanceOf(address(initializer)), 0);

        strategy.migrate(ILBPInitializer(address(initializer)));

        assertEq(address(initializer).balance, 0);
        assertEq(token.balanceOf(address(initializer)), 0);
    }

    function test_SweepsLeftoverCurrencyToFundsRecipient(FuzzParams memory p)
        public
        whenBlockIsGTEMigrationBlock
        whenCurrencyRaisedIsGTZero
    {
        (MockLBPInitializer initializer,) = _setupForMigration(p);

        uint256 balBefore = fundsRecipient.balance;
        strategy.migrate(ILBPInitializer(address(initializer)));
        assertGe(fundsRecipient.balance, balBefore);
        assertEq(address(strategy).balance, 0); // Strategy should be empty
    }

    function test_SweepsLeftoverTokensToFundsRecipient(FuzzParams memory p)
        public
        whenBlockIsGTEMigrationBlock
        whenCurrencyRaisedIsGTZero
    {
        (MockLBPInitializer initializer, MockERC20 token) = _setupForMigration(p);

        uint256 balBefore = token.balanceOf(fundsRecipient);
        strategy.migrate(ILBPInitializer(address(initializer)));
        assertEq(token.balanceOf(address(strategy)), 0);
        assertGe(token.balanceOf(fundsRecipient), balBefore);
    }
}
