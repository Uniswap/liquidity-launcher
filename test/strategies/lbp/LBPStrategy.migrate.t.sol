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
    function test_emitsCurrencySwept(uint128 _currencyRaised) public {
        // Minimum ensures currencyRaised * DEFAULT_RATE / 1e7 > 0
        _currencyRaised = uint128(bound(_currencyRaised, 1e7 / DEFAULT_RATE + 1, type(uint128).max));

        (MockLBPInitializer initializer,) = _setupForMigration(_currencyRaised, FixedPoint96.Q96);

        vm.expectEmit(true, false, false, true);
        emit ILBPStrategy.CurrencySwept(fundsRecipient, _currencyRaised);
        _migrateWithDefaults(initializer);
    }

    function test_emitsTokensSwept(uint128 _currencyRaised) public {
        _currencyRaised = uint128(bound(_currencyRaised, 1e7 / DEFAULT_RATE + 1, type(uint128).max));

        (MockLBPInitializer initializer,) = _setupForMigration(_currencyRaised, FixedPoint96.Q96);

        vm.expectEmit(true, false, false, false);
        emit ILBPStrategy.TokensSwept(fundsRecipient, 0);
        _migrateWithDefaults(initializer);
    }

    function test_emitsMigrated(uint128 _currencyRaised) public {
        _currencyRaised = uint128(bound(_currencyRaised, 1e7 / DEFAULT_RATE + 1, type(uint128).max));

        (MockLBPInitializer initializer,) = _setupForMigration(_currencyRaised, FixedPoint96.Q96);

        vm.expectEmit(false, false, false, false);
        emit ILBPStrategy.Migrated(
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(0)), 0, 0, IHooks(address(0))), 0
        );
        _migrateWithDefaults(initializer);
    }

    function test_currencyAmountCappedAtUint128Max(uint128 _currencyRaised) public {
        _currencyRaised = uint128(bound(_currencyRaised, 1e7 / DEFAULT_RATE + 1, type(uint128).max));

        (MockLBPInitializer initializer,) = _setupForMigration(_currencyRaised, FixedPoint96.Q96);

        uint256 hugeRaise = uint256(type(uint128).max) * 3;

        uint256 lpAmount = hugeRaise * DEFAULT_RATE / 1e7;
        assertGt(lpAmount, type(uint128).max);
    }
}
