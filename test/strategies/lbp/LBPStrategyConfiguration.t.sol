// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LBPStrategyTestBase} from "./base/LBPStrategyTestBase.sol";

/// @notice Integration tests for LBPStrategyConfiguration
/// Branch-level revert + fuzz tests are in btt/lbpV3/definitions/setProtocolFeeController.sol and setMinBracketRate.sol
contract LBPStrategyConfiguration_Test is LBPStrategyTestBase {
    function test_protocolFeeController_setInConstructor() public {
        assertEq(strategy.protocolFeeController(), makeAddr("protocolFeeController"));
    }

    function test_minBracketRate_setInConstructor() public view {
        assertEq(strategy.minBracketRate(), 1);
    }

    function test_storageSurvivesUpdates() public {
        address controller = makeAddr("controller");
        strategy.setProtocolFeeController(controller);
        strategy.setMinBracketRate(7777);

        assertEq(strategy.protocolFeeController(), controller);
        assertEq(strategy.minBracketRate(), 7777);

        // Update one, verify other survives
        strategy.setProtocolFeeController(makeAddr("ctrl2"));
        assertEq(strategy.protocolFeeController(), makeAddr("ctrl2"));
        assertEq(strategy.minBracketRate(), 7777);
    }
}
