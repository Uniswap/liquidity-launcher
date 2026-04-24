// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LBPStrategyTestBase} from "./base/LBPStrategyTestBase.sol";
import {ILBPStrategy} from "src/interfaces/ILBPStrategy.sol";
import {ILBPInitializer} from "src/interfaces/ILBPInitializer.sol";
import {MockLBPInitializer} from "test/mocks/MockLBPInitializer.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

contract LBPStrategy_InitializeDistribution_Test is LBPStrategyTestBase {
    function test_storesMigrationParameters(
        uint64 _endBlock,
        uint64 _migrationBlock,
        uint24 _poolLPFee,
        int24 _poolTickSpacing,
        uint128 _supplyForLP,
        uint24 _currencySplitForLP
    ) public {
        (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock,) = _boundMigratorParams(
            _endBlock, _migrationBlock, _poolLPFee, _poolTickSpacing, _supplyForLP, _currencySplitForLP
        );

        // deployedInitializer() is a test helper on MockInitializerFactory that returns the last deployed MockLBPInitializer
        (MockLBPInitializer init1,) = _initializeWith(mp, totalSupply, endBlock);

        (
            uint64 migrationBlock,
            uint24 poolLPFee,
            int24 poolTickSpacing,
            uint128 supplyForLP,
            address storedFundsRecipient,
            address storedLpPositionRecipient,
            uint24 currencySplitForLP,
            address lpHook
        ) = strategy.initializers(ILBPInitializer(address(init1)));

        assertEq(migrationBlock, mp.migrationBlock);
        assertEq(poolLPFee, mp.poolLPFee);
        assertEq(poolTickSpacing, mp.poolTickSpacing);
        assertEq(supplyForLP, mp.supplyForLP);
        assertEq(storedFundsRecipient, mp.fundsRecipient);
        assertEq(storedLpPositionRecipient, mp.lpPositionRecipient);
        assertEq(currencySplitForLP, mp.currencySplitForLP);
        assertEq(lpHook, mp.lpHook);
    }
}
