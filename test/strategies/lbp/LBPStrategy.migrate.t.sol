// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LBPStrategyTestBase} from "./base/LBPStrategyTestBase.sol";
import {ILBPStrategy} from "src/interfaces/ILBPStrategy.sol";
import {ILBPInitializer, LBPInitializationParams} from "src/interfaces/ILBPInitializer.sol";
import {MockLBPInitializer} from "test/mocks/MockLBPInitializer.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

contract LBPStrategy_Migrate_Test is LBPStrategyTestBase {
    struct MigrateFuzzParams {
        uint128 currencyRaised;
        uint160 initialPriceX96;
        uint128 tokensSold;
        uint64 endBlock;
        uint64 migrationBlock;
        uint24 poolLPFee;
        int24 poolTickSpacing;
        uint128 supplyForLP;
        uint24 currencySplitForLP;
    }

    function _setupMigration(MigrateFuzzParams memory p) internal returns (MockLBPInitializer initializer) {
        (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock, uint128 auctionSupply) = _boundMigratorParams(
            p.endBlock, p.migrationBlock, p.poolLPFee, p.poolTickSpacing, p.supplyForLP, p.currencySplitForLP
        );
        p.currencyRaised = _boundCurrencyRaised(p.currencyRaised, mp.currencySplitForLP);
        p.initialPriceX96 = _boundInitialPriceX96(p.initialPriceX96);
        p.tokensSold = uint128(bound(p.tokensSold, 1, auctionSupply));

        (initializer,) =
            _setupForMigration(mp, totalSupply, endBlock, p.currencyRaised, p.initialPriceX96, p.tokensSold);
    }

    function test_emitsCurrencySwept(MigrateFuzzParams memory p) public {
        MockLBPInitializer initializer = _setupMigration(p);

        // Check indexed param (fundsRecipient) but not data — exact amount may differ due to pool initialization dust
        vm.expectEmit(true, false, false, false);
        emit ILBPStrategy.CurrencySwept(fundsRecipient, 0);
        strategy.migrate(ILBPInitializer(address(initializer)));
    }

    function test_emitsTokensSwept(MigrateFuzzParams memory p) public {
        MockLBPInitializer initializer = _setupMigration(p);

        vm.expectEmit(true, false, false, false);
        emit ILBPStrategy.TokensSwept(fundsRecipient, 0);
        strategy.migrate(ILBPInitializer(address(initializer)));
    }

    function test_emitsMigrated(MigrateFuzzParams memory p) public {
        MockLBPInitializer initializer = _setupMigration(p);

        vm.expectEmit(false, false, false, false);
        emit ILBPStrategy.Migrated(
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(0)), 0, 0, IHooks(address(0))), 0
        );
        strategy.migrate(ILBPInitializer(address(initializer)));
    }

    function test_currencyAmountCappedAtUint128Max(MigrateFuzzParams memory p) public {
        // Use a high split so that hugeRaise * split / 1e7 > uint128.max
        p.currencySplitForLP = uint24(bound(p.currencySplitForLP, 5e6, 1e7));

        (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock, uint128 auctionSupply) = _boundMigratorParams(
            p.endBlock, p.migrationBlock, p.poolLPFee, p.poolTickSpacing, p.supplyForLP, p.currencySplitForLP
        );
        p.tokensSold = uint128(bound(p.tokensSold, 1, auctionSupply));
        p.initialPriceX96 = _boundInitialPriceX96(p.initialPriceX96);

        uint256 hugeRaise = uint256(type(uint128).max) * 3;

        (MockLBPInitializer initializer, MockERC20 token) = _initializeWith(mp, totalSupply, endBlock);
        initializer.setLbpInitializationParams(
            LBPInitializationParams({
                initialPriceX96: p.initialPriceX96, tokensSold: p.tokensSold, currencyRaised: hugeRaise
            })
        );

        // Fund the initializer with the huge raise + tokens
        vm.deal(address(initializer), hugeRaise);
        token.transfer(address(initializer), totalSupply);
        vm.roll(mp.migrationBlock);
        // Mock modifyLiquidities — _createPositionPlan is a stub
        vm.mockCall(address(POSITION_MANAGER), abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector), "");

        uint256 recipientBalBefore = fundsRecipient.balance;

        // Migrate — should not revert, currency amount gets capped at uint128.max
        strategy.migrate(ILBPInitializer(address(initializer)));

        // Nearly all currency ends up at fundsRecipient — pool initialization may consume dust
        uint256 received = fundsRecipient.balance - recipientBalBefore;
        assertGe(received, hugeRaise - 1);

        // Strategy should be empty
        assertEq(address(strategy).balance, 0);
        assertEq(token.balanceOf(address(strategy)), 0);
    }
}
