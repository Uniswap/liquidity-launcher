// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LBPStrategyTestBase} from "./base/LBPStrategyTestBase.sol";
import {ILBPStrategy} from "src/interfaces/ILBPStrategy.sol";
import {ILBPInitializer} from "src/interfaces/ILBPInitializer.sol";
import {MockLBPInitializer} from "test/mocks/MockLBPInitializer.sol";

contract LBPStrategy_MultiAuction_Test is LBPStrategyTestBase {
    function test_twoAuctions_independentIdentifiers() public {
        (MockLBPInitializer init1,) = _initializeWithDefaults();

        ILBPStrategy.MigratorParameters memory params2 = _defaultMigratorParams();
        params2.migrationBlock = uint64(block.number) + 300;
        factory.setCustodyTokens(params2.supplyForLP + params2.custodyTokens);

        strategy.initializeDistribution(
            address(token), DEFAULT_TOTAL_SUPPLY, _encodeConfigData(params2, _defaultBreakpoints(), hex""), bytes32(0)
        );
        MockLBPInitializer init2 = factory.deployedInitializer();

        bytes32 id1 = strategy.initializers(ILBPInitializer(address(init1)));
        bytes32 id2 = strategy.initializers(ILBPInitializer(address(init2)));

        assertNotEq(id1, bytes32(0));
        assertNotEq(id2, bytes32(0));
        assertNotEq(id1, id2);
    }

    function test_twoAuctions_cannotSwapParams() public {
        (MockLBPInitializer init1,) = _initializeWithDefaults();

        ILBPStrategy.MigratorParameters memory params2 = _defaultMigratorParams();
        params2.migrationBlock = uint64(block.number) + 300;
        factory.setCustodyTokens(params2.supplyForLP + params2.custodyTokens);

        strategy.initializeDistribution(
            address(token), DEFAULT_TOTAL_SUPPLY, _encodeConfigData(params2, _defaultBreakpoints(), hex""), bytes32(0)
        );

        vm.roll(params2.migrationBlock);
        vm.expectRevert(ILBPStrategy.InvalidMigrationParameters.selector);
        strategy.migrate(ILBPInitializer(address(init1)), params2, _defaultBreakpoints());
    }
}
