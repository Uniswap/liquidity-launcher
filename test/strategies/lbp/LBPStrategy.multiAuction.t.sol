// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LBPStrategyTestBase} from "./base/LBPStrategyTestBase.sol";
import {ILBPStrategy} from "src/interfaces/ILBPStrategy.sol";
import {ILBPInitializer} from "src/interfaces/ILBPInitializer.sol";
import {MockLBPInitializer} from "test/mocks/MockLBPInitializer.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

contract LBPStrategy_MultiAuction_Test is LBPStrategyTestBase {
    function test_twoAuctions_independentParams(
        uint64 _endBlock1,
        uint64 _endBlock2,
        uint64 _migrationBlock1,
        uint64 _migrationBlock2,
        uint24 _poolLPFee,
        int24 _poolTickSpacing,
        uint128 _supplyForLP,
        uint24 _currencySplitForLP
    ) public {
        (ILBPStrategy.MigratorParameters memory params1, uint128 totalSupply1, uint64 endBlock1,) = _boundMigratorParams(
            _endBlock1, _migrationBlock1, _poolLPFee, _poolTickSpacing, _supplyForLP, _currencySplitForLP
        );
        (ILBPStrategy.MigratorParameters memory params2, uint128 totalSupply2, uint64 endBlock2,) = _boundMigratorParams(
            _endBlock2, _migrationBlock2, _poolLPFee, _poolTickSpacing, _supplyForLP, _currencySplitForLP
        );
        vm.assume(params1.migrationBlock != params2.migrationBlock);

        (MockLBPInitializer init1,) = _initializeWith(params1, totalSupply1, endBlock1);
        (MockLBPInitializer init2,) = _initializeWith(params2, totalSupply2, endBlock2);

        (uint64 stored1,,,,,,,,) = strategy.initializers(ILBPInitializer(address(init1)));
        (uint64 stored2,,,,,,,,) = strategy.initializers(ILBPInitializer(address(init2)));

        assertEq(stored1, params1.migrationBlock);
        assertEq(stored2, params2.migrationBlock);
        assertTrue(stored1 != stored2);
    }
}
