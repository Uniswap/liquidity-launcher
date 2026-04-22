// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LBPStrategyTestBase} from "./base/LBPStrategyTestBase.sol";

/// @notice Integration tests for LBPStrategyConfiguration
/// Branch-level revert + fuzz tests are in btt/lbpV3/definitions/setProtocolFeeController.sol and setMinSplitForLp.sol
contract LBPStrategyConfiguration_Test is LBPStrategyTestBase {
    function test_protocolFeeController_setInConstructor() public {
        assertEq(strategy.protocolFeeController(), makeAddr("protocolFeeController"));
    }

    function test_minSplitForLp_setInConstructor() public view {
        assertEq(strategy.minSplitForLp(), 1);
    }

    function test_storageSurvivesUpdates() public {
        address controller = makeAddr("controller");
        strategy.setProtocolFeeController(controller);
        strategy.setMinSplitForLp(7777);

        assertEq(strategy.protocolFeeController(), controller);
        assertEq(strategy.minSplitForLp(), 7777);

        // Update one, verify other survives
        strategy.setProtocolFeeController(makeAddr("ctrl2"));
        assertEq(strategy.protocolFeeController(), makeAddr("ctrl2"));
        assertEq(strategy.minSplitForLp(), 7777);
    }
}
