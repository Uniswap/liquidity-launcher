// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LBPStrategyTestBase} from "./base/LBPStrategyTestBase.sol";
import {ILBPStrategy} from "src/interfaces/ILBPStrategy.sol";
import {ILBPInitializer} from "src/interfaces/ILBPInitializer.sol";
import {MockLBPInitializer} from "test/mocks/MockLBPInitializer.sol";

/// @notice Integration and specific-value tests for initializeDistribution
/// Branch-level revert + fuzz tests are in btt/lbpV3/definitions/initializeDistribution.sol
contract LBPStrategy_InitializeDistribution_Test is LBPStrategyTestBase {
    function test_identifierIsDeterministic() public {
        ILBPStrategy.MigratorParameters memory mp = _defaultMigratorParams();
        factory.setCustodyTokens(mp.supplyForLP + mp.custodyTokens);

        strategy.initializeDistribution(address(token), DEFAULT_TOTAL_SUPPLY, _encodeConfigData(mp, hex""), bytes32(0));
        MockLBPInitializer init1 = factory.deployedInitializer();
        bytes32 id1 = strategy.initializers(ILBPInitializer(address(init1)));

        bytes32 expectedId = keccak256(
            abi.encode(
                mp.migrationBlock,
                mp.poolLPFee,
                mp.poolTickSpacing,
                mp.supplyForLP,
                mp.fundsRecipient,
                mp.custodyTokens,
                mp.lpPositionRecipient,
                mp.tier1Rate,
                mp.tier1Threshold,
                mp.tier2Rate,
                mp.tier2Threshold,
                mp.tier3Rate,
                mp.lpHook
            )
        );
        assertEq(id1, expectedId);
    }

    function test_emitsInitializerCreated() public {
        ILBPStrategy.MigratorParameters memory mp = _defaultMigratorParams();
        factory.setCustodyTokens(mp.supplyForLP + mp.custodyTokens);

        vm.expectEmit(false, false, false, true);
        emit ILBPStrategy.InitializerCreated(ILBPInitializer(address(0)), mp);
        strategy.initializeDistribution(address(token), DEFAULT_TOTAL_SUPPLY, _encodeConfigData(mp, hex""), bytes32(0));
    }
}
