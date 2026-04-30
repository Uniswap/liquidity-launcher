// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {LBPStrategyTestBase} from "../../../../base/LBPStrategyTestBase.sol";
import {ILBPStrategy} from "src/interfaces/ILBPStrategy.sol";
import {ILBPInitializer, LBPInitializationParams} from "src/interfaces/ILBPInitializer.sol";
import {MockLBPInitializer} from "test/mocks/MockLBPInitializer.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
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
    struct MigrationFuzzParams {
        uint64 endBlock;
        uint64 migrationBlock;
        uint24 poolLPFee;
        int24 poolTickSpacing;
        uint128 supplyForLP;
        uint128 currencyRaised;
    }

    function _setupMigration(MigrationFuzzParams memory p)
        internal
        returns (MockLBPInitializer initializer, MockERC20 token)
    {
        (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock, uint128 auctionSupply) =
            _boundMigratorParams(p.endBlock, p.migrationBlock, p.poolLPFee, p.poolTickSpacing, p.supplyForLP);
        p.currencyRaised = _boundCurrencyRaised(p.currencyRaised, DEFAULT_RATE);
        uint128 tokensSold = uint128(bound(p.currencyRaised, 1, auctionSupply));

        (initializer, token) = _setupForMigration(
            mp, totalSupply, endBlock, p.currencyRaised, _boundInitialPriceX96(uint160(p.currencyRaised)), tokensSold
        );
    }

    function test_WhenInitializerIsUnregistered(uint64 _currentBlock) public {
        _currentBlock = uint64(bound(_currentBlock, 1, type(uint64).max));
        vm.roll(_currentBlock);

        ILBPInitializer unregistered = ILBPInitializer(
            address(new MockLBPInitializer(address(1), address(0), 0, 0, address(strategy), address(strategy), 0, 0))
        );

        (ILBPStrategy.MigratorParameters memory storedParams) = strategy.initializers(unregistered);
        assertEq(storedParams.migrationBlock, 0);

        vm.expectRevert(abi.encodeWithSelector(ILBPStrategy.MigrationNotAllowed.selector, uint64(0), _currentBlock));
        strategy.migrate(unregistered);
    }

    function test_WhenBlockIsLTMigrationBlock(
        uint64 _currentBlock,
        uint64 _endBlock,
        uint64 _migrationBlock,
        uint24 _poolLPFee,
        int24 _poolTickSpacing,
        uint128 _supplyForLP
    ) public {
        (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock,) =
            _boundMigratorParams(_endBlock, _migrationBlock, _poolLPFee, _poolTickSpacing, _supplyForLP);

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

    function test_WhenCurrencyRaisedIsZero(
        uint160 _initialPriceX96,
        uint64 _endBlock,
        uint64 _migrationBlock,
        uint24 _poolLPFee,
        int24 _poolTickSpacing,
        uint128 _supplyForLP
    ) public whenBlockIsGTEMigrationBlock {
        _initialPriceX96 = _boundInitialPriceX96(_initialPriceX96);

        (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock,) =
            _boundMigratorParams(_endBlock, _migrationBlock, _poolLPFee, _poolTickSpacing, _supplyForLP);

        (MockLBPInitializer initializer, MockERC20 token) = _initializeWith(mp, totalSupply, endBlock);

        initializer.setLbpInitializationParams(
            LBPInitializationParams({initialPriceX96: _initialPriceX96, tokensSold: 0, currencyRaised: 0})
        );
        token.transfer(address(initializer), totalSupply);
        vm.roll(mp.migrationBlock);

        vm.expectRevert(ILBPStrategy.NoCurrencyRaised.selector);
        strategy.migrate(ILBPInitializer(address(initializer)));
    }

    modifier whenCurrencyRaisedIsGTZero() {
        _;
    }

    function test_CallsSweepOnInitializer(MigrationFuzzParams memory p)
        public
        whenBlockIsGTEMigrationBlock
        whenCurrencyRaisedIsGTZero
    {
        (MockLBPInitializer initializer,) = _setupMigration(p);

        strategy.migrate(ILBPInitializer(address(initializer)));

        assertTrue(initializer.sweepCurrencyCalled());
        assertTrue(initializer.sweepUnsoldTokensCalled());
    }

    function test_SweepsLeftoverCurrencyToFundsRecipient(MigrationFuzzParams memory p)
        public
        whenBlockIsGTEMigrationBlock
        whenCurrencyRaisedIsGTZero
    {
        (MockLBPInitializer initializer,) = _setupMigration(p);

        uint256 balBefore = fundsRecipient.balance;
        strategy.migrate(ILBPInitializer(address(initializer)));
        assertGe(fundsRecipient.balance, balBefore);
    }

    function test_SweepsLeftoverTokensToFundsRecipient(MigrationFuzzParams memory p)
        public
        whenBlockIsGTEMigrationBlock
        whenCurrencyRaisedIsGTZero
    {
        (MockLBPInitializer initializer, MockERC20 token) = _setupMigration(p);

        strategy.migrate(ILBPInitializer(address(initializer)));
        assertEq(token.balanceOf(address(strategy)), 0);
    }
}
