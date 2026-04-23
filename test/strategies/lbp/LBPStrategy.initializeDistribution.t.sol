// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LBPStrategyTestBase} from "./base/LBPStrategyTestBase.sol";
import {ILBPStrategy} from "src/interfaces/ILBPStrategy.sol";
import {ILBPInitializer} from "src/interfaces/ILBPInitializer.sol";
import {MockLBPInitializer} from "test/mocks/MockLBPInitializer.sol";

/// @notice Integration and specific-value tests for initializeDistribution
/// Branch-level revert + fuzz tests are in btt/lbpV3/definitions/initializeDistribution.sol
contract LBPStrategy_InitializeDistribution_Test is LBPStrategyTestBase {
    function test_storesMigrationParameters() public {
        ILBPStrategy.MigratorParameters memory mp = _defaultMigratorParams();
        factory.setCustodyTokens(mp.supplyForLP + mp.custodyTokens);

        strategy.initializeDistribution(address(token), DEFAULT_TOTAL_SUPPLY, _encodeConfigData(mp, hex""), bytes32(0));
        // deployedInitializer() is a test helper on MockInitializerFactory that returns the last deployed MockLBPInitializer
        MockLBPInitializer init1 = factory.deployedInitializer();

        (
            uint64 migrationBlock,
            uint24 poolLPFee,
            int24 poolTickSpacing,
            uint128 supplyForLP,
            address storedFundsRecipient,
            uint128 custodyTokens,
            address storedLpPositionRecipient,
            uint24 currencySplitForLP,
            address lpHook
        ) = strategy.initializers(ILBPInitializer(address(init1)));

        assertEq(migrationBlock, mp.migrationBlock);
        assertEq(poolLPFee, mp.poolLPFee);
        assertEq(poolTickSpacing, mp.poolTickSpacing);
        assertEq(supplyForLP, mp.supplyForLP);
        assertEq(storedFundsRecipient, mp.fundsRecipient);
        assertEq(custodyTokens, mp.custodyTokens);
        assertEq(storedLpPositionRecipient, mp.lpPositionRecipient);
        assertEq(currencySplitForLP, mp.currencySplitForLP);
        assertEq(lpHook, mp.lpHook);
    }

    function test_emitsInitializerCreated() public {
        ILBPStrategy.MigratorParameters memory mp = _defaultMigratorParams();
        factory.setCustodyTokens(mp.supplyForLP + mp.custodyTokens);

        vm.expectEmit(false, false, false, true);
        emit ILBPStrategy.InitializerCreated(ILBPInitializer(address(0)), mp);
        strategy.initializeDistribution(address(token), DEFAULT_TOTAL_SUPPLY, _encodeConfigData(mp, hex""), bytes32(0));
    }
}
