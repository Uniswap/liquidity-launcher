// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LBPStrategyTestBase} from "./base/LBPStrategyTestBase.sol";
import {ILBPStrategy} from "src/interfaces/ILBPStrategy.sol";
import {ILBPInitializer, LBPInitializationParams} from "src/interfaces/ILBPInitializer.sol";
import {MockLBPInitializer} from "test/mocks/MockLBPInitializer.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";

/// @notice Integration and event tests for migrate
/// Branch-level revert + fuzz tests are in btt/lbpV3/definitions/migrate/validateMigration.sol
contract LBPStrategy_Migrate_Test is LBPStrategyTestBase {
    function test_emitsCurrencySwept() public {
        (MockLBPInitializer initializer, ILBPStrategy.MigratorParameters memory mp) =
            _setupForMigration(10e18, FixedPoint96.Q96);

        vm.expectEmit(true, false, false, true);
        emit ILBPStrategy.CurrencySwept(fundsRecipient, 10e18);
        _migrateWithDefaults(initializer);
    }

    function test_emitsTokensSwept() public {
        (MockLBPInitializer initializer, ILBPStrategy.MigratorParameters memory mp) =
            _setupForMigration(10e18, FixedPoint96.Q96);

        vm.expectEmit(true, false, false, false);
        emit ILBPStrategy.TokensSwept(fundsRecipient, 0);
        _migrateWithDefaults(initializer);
    }

    function test_emitsMigrated() public {
        (MockLBPInitializer initializer, ILBPStrategy.MigratorParameters memory mp) =
            _setupForMigration(10e18, FixedPoint96.Q96);

        vm.expectEmit(false, false, false, false);
        emit ILBPStrategy.Migrated(
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(0)), 0, 0, IHooks(address(0))), 0
        );
        _migrateWithDefaults(initializer);
    }

    function test_currencyAmountCappedAtUint128Max() public {
        uint256 hugeRaise = uint256(type(uint128).max) * 3;

        (MockLBPInitializer initializer,) = _initializeWithDefaults();
        initializer.setLbpInitializationParams(
            LBPInitializationParams({initialPriceX96: FixedPoint96.Q96, tokensSold: 100e18, currencyRaised: hugeRaise})
        );

        uint256 lpAmount = hugeRaise * DEFAULT_RATE / 1e7;
        assertGt(lpAmount, type(uint128).max);
    }
}
