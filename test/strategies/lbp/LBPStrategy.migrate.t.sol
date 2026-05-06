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
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

contract LBPStrategy_Migrate_Test is LBPStrategyTestBase {
    function test_emitsCurrencySwept(FuzzParams memory p) public {
        (MockLBPInitializer initializer,) = _setupForMigration(p);

        // Check indexed param (fundsRecipient) but not data — exact amount may differ due to pool initialization dust
        vm.expectEmit(true, false, false, false);
        emit ILBPStrategy.CurrencySwept(fundsRecipient, 0);
        strategy.migrate(ILBPInitializer(address(initializer)));
    }

    function test_emitsTokensSwept(FuzzParams memory p) public {
        (MockLBPInitializer initializer,) = _setupForMigration(p);

        vm.expectEmit(true, false, false, false);
        emit ILBPStrategy.TokensSwept(fundsRecipient, 0);
        strategy.migrate(ILBPInitializer(address(initializer)));
    }

    function test_emitsMigrated(FuzzParams memory p) public {
        (MockLBPInitializer initializer,) = _setupForMigration(p);

        vm.expectEmit(false, false, false, false);
        emit ILBPStrategy.Migrated(
            ILBPInitializer(address(0)),
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(0)), 0, 0, IHooks(address(0))),
            0
        );
        strategy.migrate(ILBPInitializer(address(initializer)));
    }

    function test_currencyAmountCappedAtInt128Max(FuzzParams memory p, uint256 _hugeRaise) public {
        // Floor split at 50% so minRaise stays in a practical range for vm.deal
        p.currencySplitForLP = uint24(bound(p.currencySplitForLP, 5e6, type(uint24).max));

        (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock, uint128 auctionSupply) =
            _boundMigratorParams(p);
        p.tokensSold = uint128(bound(p.tokensSold, 1, auctionSupply));
        p.initialPriceX96 = _boundInitialPriceX96(p.initialPriceX96);

        uint128 maxV4Delta = uint128(type(int128).max);
        // Bound so that hugeRaise * split / 1e7 > int128.max (triggers the cap).
        uint256 minRaise = uint256(maxV4Delta) * 1e7 / mp.currencySplitForLP + 1;
        uint256 hugeRaise = bound(_hugeRaise, minRaise, type(uint256).max / mp.currencySplitForLP);

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
        // Keep this test focused on the int128 cap and sweep behavior; position execution is covered elsewhere.
        vm.mockCall(address(POSITION_MANAGER), abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector), "");

        uint256 recipientBalBefore = fundsRecipient.balance;

        // Migrate — should not revert, currency amount gets capped at int128.max
        strategy.migrate(ILBPInitializer(address(initializer)));

        uint256 received = fundsRecipient.balance - recipientBalBefore;
        assertApproxEqAbs(received, hugeRaise, 2);

        // Strategy should be empty
        assertEq(address(strategy).balance, 0);
        assertEq(token.balanceOf(address(strategy)), 0);
    }

    function test_currencyAndTokenAmountsCappedAtInt128Max(FuzzParams memory p) public {
        uint128 maxV4Delta = uint128(type(int128).max);

        p.currencySplitForLP = 1e7;
        p.auctionSupply = 1;
        p.supplyForLP = maxV4Delta + 1;
        p.initialPriceX96 = _boundInitialPriceX96(p.initialPriceX96);

        (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock, uint128 auctionSupply) =
            _boundMigratorParams(p);
        p.tokensSold = uint128(bound(p.tokensSold, 1, auctionSupply));

        uint256 currencyRaised = uint256(maxV4Delta) + 1;
        (MockLBPInitializer initializer, MockERC20 token) = _initializeWith(mp, totalSupply, endBlock);
        initializer.setLbpInitializationParams(
            LBPInitializationParams({
                initialPriceX96: p.initialPriceX96, tokensSold: p.tokensSold, currencyRaised: currencyRaised
            })
        );

        vm.deal(address(initializer), currencyRaised);
        token.transfer(address(initializer), totalSupply);
        vm.roll(mp.migrationBlock);

        uint256 recipientBalBefore = fundsRecipient.balance;
        uint256 recipientTokenBalBefore = token.balanceOf(fundsRecipient);

        strategy.migrate(ILBPInitializer(address(initializer)));

        assertGt(uint256(currencyRaised), maxV4Delta);
        assertGt(mp.supplyForLP, maxV4Delta);
        assertGt(fundsRecipient.balance, recipientBalBefore);
        assertGt(token.balanceOf(fundsRecipient), recipientTokenBalBefore);
        assertEq(address(strategy).balance, 0);
        assertEq(token.balanceOf(address(strategy)), 0);
    }
}
