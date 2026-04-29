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
        ILBPStrategy.Breakpoint[] memory bp = _defaultBreakpoints();
        strategy.initializeDistribution(
            address(token), DEFAULT_TOTAL_SUPPLY, _encodeConfigData(mp, bp, _defaultInitializerParams(mp)), bytes32(0)
        );
        MockLBPInitializer init1 = factory.deployedInitializer();

        (ILBPStrategy.MigratorParameters memory storedParams) = strategy.initializers(ILBPInitializer(address(init1)));

        assertEq(storedParams.migrationBlock, mp.migrationBlock);
        assertEq(storedParams.poolLPFee, mp.poolLPFee);
        assertEq(storedParams.poolTickSpacing, mp.poolTickSpacing);
        assertEq(storedParams.supplyForLP, mp.supplyForLP);
    }

    function test_emitsInitializerCreated() public {
        ILBPStrategy.MigratorParameters memory mp = _defaultMigratorParams();
        ILBPStrategy.Breakpoint[] memory bp = _defaultBreakpoints();
        vm.expectEmit(false, false, false, false);
        emit ILBPStrategy.InitializerCreated(ILBPInitializer(address(0)), mp, bp);
        strategy.initializeDistribution(
            address(token), DEFAULT_TOTAL_SUPPLY, _encodeConfigData(mp, bp, _defaultInitializerParams(mp)), bytes32(0)
        );
    }
}
