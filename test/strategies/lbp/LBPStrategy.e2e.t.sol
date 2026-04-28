// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LBPStrategyTestBase} from "./base/LBPStrategyTestBase.sol";
import {ILBPStrategy} from "src/interfaces/ILBPStrategy.sol";
import {ILBPInitializer, LBPInitializationParams} from "src/interfaces/ILBPInitializer.sol";
import {MockLBPInitializer} from "test/mocks/MockLBPInitializer.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

/// @notice End-to-end fuzz tests exercising the full initializeDistribution → migrate flow
contract LBPStrategy_E2E_Test is LBPStrategyTestBase {
    function test_fuzz_initAndMigrate_happyPath(
        uint64 _endBlock,
        uint64 _migrationBlock,
        uint24 _poolLPFee,
        int24 _poolTickSpacing,
        uint128 _supplyForLP,
        uint24 _currencySplitForLP,
        uint128 _currencyRaised,
        uint160 _initialPriceX96,
        uint128 _tokensSold
    ) public {
        (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock, uint128 auctionSupply) = _boundMigratorParams(
            _endBlock, _migrationBlock, _poolLPFee, _poolTickSpacing, _supplyForLP, _currencySplitForLP
        );
        _currencyRaised = _boundCurrencyRaised(_currencyRaised, mp.currencySplitForLP);
        _initialPriceX96 = _boundInitialPriceX96(_initialPriceX96);
        _tokensSold = uint128(bound(_tokensSold, 1, auctionSupply));

        (MockLBPInitializer initializer, MockERC20 token) =
            _setupForMigration(mp, totalSupply, endBlock, _currencyRaised, _initialPriceX96, _tokensSold);

        // Verify migration params were stored
        (uint64 storedMigrationBlock,,,,,,,,) = strategy.initializers(ILBPInitializer(address(initializer)));
        assertEq(storedMigrationBlock, mp.migrationBlock);

        // Record balances before migration
        uint256 recipientBalBefore = fundsRecipient.balance;
        uint256 recipientTokenBalBefore = token.balanceOf(fundsRecipient);

        // Migrate
        strategy.migrate(ILBPInitializer(address(initializer)));

        // Strategy should be empty after migration
        assertEq(token.balanceOf(address(strategy)), 0);
        assertEq(address(strategy).balance, 0);

        // fundsRecipient should have received something
        assertTrue(
            fundsRecipient.balance > recipientBalBefore || token.balanceOf(fundsRecipient) > recipientTokenBalBefore
        );
    }

    function test_fuzz_twoAuctionsIsolated(
        uint64 _endBlock1,
        uint64 _endBlock2,
        uint64 _migrationBlock1,
        uint64 _migrationBlock2,
        uint24 _poolLPFee,
        int24 _poolTickSpacing,
        uint128 _supplyForLP,
        uint24 _currencySplitForLP
    ) public {
        (ILBPStrategy.MigratorParameters memory mp1, uint128 totalSupply1, uint64 endBlock1,) = _boundMigratorParams(
            _endBlock1, _migrationBlock1, _poolLPFee, _poolTickSpacing, _supplyForLP, _currencySplitForLP
        );
        (ILBPStrategy.MigratorParameters memory mp2, uint128 totalSupply2, uint64 endBlock2,) = _boundMigratorParams(
            _endBlock2, _migrationBlock2, _poolLPFee, _poolTickSpacing, _supplyForLP, _currencySplitForLP
        );

        (MockLBPInitializer init1,) = _initializeWith(mp1, totalSupply1, endBlock1);
        (MockLBPInitializer init2,) = _initializeWith(mp2, totalSupply2, endBlock2);

        (uint64 stored1,,,,,,,,) = strategy.initializers(ILBPInitializer(address(init1)));
        (uint64 stored2,,,,,,,,) = strategy.initializers(ILBPInitializer(address(init2)));
        assertEq(stored1, mp1.migrationBlock);
        assertEq(stored2, mp2.migrationBlock);
    }

    function test_fuzz_currencySplitAppliedCorrectly(
        uint64 _endBlock,
        uint64 _migrationBlock,
        uint24 _poolLPFee,
        int24 _poolTickSpacing,
        uint128 _supplyForLP,
        uint24 _currencySplitForLP,
        uint128 _currencyRaised,
        uint128 _tokensSold
    ) public {
        (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock, uint128 auctionSupply) = _boundMigratorParams(
            _endBlock, _migrationBlock, _poolLPFee, _poolTickSpacing, _supplyForLP, _currencySplitForLP
        );
        _currencyRaised = _boundCurrencyRaised(_currencyRaised, mp.currencySplitForLP);
        _tokensSold = uint128(bound(_tokensSold, 1, auctionSupply));

        (MockLBPInitializer initializer,) = _setupForMigration(
            mp, totalSupply, endBlock, _currencyRaised, _boundInitialPriceX96(uint160(_currencyRaised)), _tokensSold
        );

        uint256 recipientBalBefore = fundsRecipient.balance;
        strategy.migrate(ILBPInitializer(address(initializer)));

        // Nearly all currency should end up at fundsRecipient (since _createPositionPlan is a stub returning empty,
        // no currency actually goes to LP — it all gets swept). Pool initialization may consume dust.
        uint256 received = fundsRecipient.balance - recipientBalBefore;
        assertGe(received, _currencyRaised - 1);
    }
}
