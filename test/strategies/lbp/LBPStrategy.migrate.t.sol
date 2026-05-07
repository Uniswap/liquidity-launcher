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
    function test_emitsCurrencySwept(MigrationFuzzParams memory p) public {
        (MockLBPInitializer initializer,) = _setupForMigration(p);

        // Check indexed param (fundsRecipient) but not data — exact amount may differ due to pool initialization dust
        vm.expectEmit(true, false, false, false);
        emit ILBPStrategy.CurrencySwept(fundsRecipient, 0);
        strategy.migrate(ILBPInitializer(address(initializer)));
    }

    function test_emitsTokensSwept(MigrationFuzzParams memory p) public {
        (MockLBPInitializer initializer,) = _setupForMigration(p);

        vm.expectEmit(true, false, false, false);
        emit ILBPStrategy.TokensSwept(fundsRecipient, 0);
        strategy.migrate(ILBPInitializer(address(initializer)));
    }

    function test_emitsMigrated(MigrationFuzzParams memory p) public {
        (MockLBPInitializer initializer,) = _setupForMigration(p);

        vm.expectEmit(false, false, false, false);
        emit ILBPStrategy.Migrated(
            ILBPInitializer(address(0)),
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(0)), 0, 0, IHooks(address(0))),
            0
        );
        strategy.migrate(ILBPInitializer(address(initializer)));
    }

    function test_currencyAmountCappedAtInt128Max(MigrationFuzzParams memory p, uint256 _hugeRaise) public {
        // Use a single bracket with rate >= 50% so minRaise stays in a practical range for vm.deal
        uint24 rate = uint24(bound(p.bpParams.rate0, strategy.MAX_BRACKET_RATE() / 2, strategy.MAX_BRACKET_RATE()));
        ILBPStrategy.LpAllocationBracket[] memory bp = new ILBPStrategy.LpAllocationBracket[](1);
        bp[0] = ILBPStrategy.LpAllocationBracket({lowerThreshold: 0, rate: rate});

        (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock, uint128 auctionSupply) =
            _boundMigratorParams(p);
        p.tokensSold = uint128(bound(p.tokensSold, 1, auctionSupply));
        p.initialPriceX96 = _boundInitialPriceX96(p.initialPriceX96);

        // Bound so that hugeRaise * rate / MAX_BRACKET_RATE > int128.max (triggers the cap).
        // _calculateCurrencyAmountForLp does currencyRaised * rate, so cap hugeRaise to avoid that overflow.
        uint256 minRaise = uint256(uint128(type(int128).max)) * strategy.MAX_BRACKET_RATE() / rate + 1;
        uint256 hugeRaise = bound(_hugeRaise, minRaise, type(uint256).max / rate);

        (MockLBPInitializer initializer, MockERC20 token) = _initializeWith(mp, totalSupply, endBlock, bp);
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

        // Migrate — should not revert, currency amount gets capped at int128.max
        strategy.migrate(ILBPInitializer(address(initializer)));

        uint256 received = fundsRecipient.balance - recipientBalBefore;
        assertApproxEqAbs(received, hugeRaise, 2);

        // Strategy should be empty
        assertEq(address(strategy).balance, 0);
        assertEq(token.balanceOf(address(strategy)), 0);
    }
}
