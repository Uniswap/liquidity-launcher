// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LBPStrategyTestBase} from "./base/LBPStrategyTestBase.sol";
import {ILBPStrategy} from "src/interfaces/ILBPStrategy.sol";
import {ILBPInitializer} from "src/interfaces/ILBPInitializer.sol";
import {MockLBPInitializer} from "test/mocks/MockLBPInitializer.sol";

contract LBPStrategy_MultiAuction_Test is LBPStrategyTestBase {
    function test_twoAuctions_independentParams(
        uint64 _endBlock1,
        uint64 _endBlock2,
        uint64 _migrationBlock1,
        uint64 _migrationBlock2,
        uint24 _poolLPFee,
        int24 _poolTickSpacing,
        uint128 _supplyForLP
    ) public {
        (ILBPStrategy.MigratorParameters memory mp1, uint128 totalSupply1, uint64 endBlock1,) =
            _boundMigratorParams(_endBlock1, _migrationBlock1, _poolLPFee, _poolTickSpacing, _supplyForLP);
        (ILBPStrategy.MigratorParameters memory mp2, uint128 totalSupply2, uint64 endBlock2,) =
            _boundMigratorParams(_endBlock2, _migrationBlock2, _poolLPFee, _poolTickSpacing, _supplyForLP);

        (MockLBPInitializer init1,) = _initializeWith(mp1, totalSupply1, endBlock1);
        (MockLBPInitializer init2,) = _initializeWith(mp2, totalSupply2, endBlock2);

        (ILBPStrategy.MigratorParameters memory stored1) = strategy.initializers(ILBPInitializer(address(init1)));
        (ILBPStrategy.MigratorParameters memory stored2) = strategy.initializers(ILBPInitializer(address(init2)));

        assertEq(stored1.migrationBlock, mp1.migrationBlock);
        assertEq(stored2.migrationBlock, mp2.migrationBlock);
    }
}
