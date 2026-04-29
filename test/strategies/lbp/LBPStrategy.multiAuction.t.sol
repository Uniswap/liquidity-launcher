// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LBPStrategyTestBase} from "./base/LBPStrategyTestBase.sol";
import {ILBPStrategy} from "src/interfaces/ILBPStrategy.sol";
import {ILBPInitializer} from "src/interfaces/ILBPInitializer.sol";
import {MockLBPInitializer} from "test/mocks/MockLBPInitializer.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

contract LBPStrategy_MultiAuction_Test is LBPStrategyTestBase {
    function test_twoAuctions_independentParams() public {
        (MockLBPInitializer init1, ILBPStrategy.MigratorParameters memory params1) = _initializeWithDefaults();

        ILBPStrategy.MigratorParameters memory params2 = _defaultMigratorParams();
        params2.migrationBlock = uint64(block.number) + 300;
        factory.setCustodyTokens(params2.supplyForLP + params2.custodyTokens);

        strategy.initializeDistribution(
            address(token), DEFAULT_TOTAL_SUPPLY, _encodeConfigData(params2, _defaultBreakpoints(), hex""), bytes32(0)
        );
        MockLBPInitializer init2 = factory.deployedInitializer();

        (ILBPStrategy.MigratorParameters memory storedParams1) = strategy.initializers(ILBPInitializer(address(init1)));
        (ILBPStrategy.MigratorParameters memory storedParams2) = strategy.initializers(ILBPInitializer(address(init2)));

        assertEq(storedParams1.migrationBlock, params1.migrationBlock);
        assertEq(storedParams2.migrationBlock, params2.migrationBlock);
        assertTrue(storedParams1.migrationBlock != storedParams2.migrationBlock);
    }
}
