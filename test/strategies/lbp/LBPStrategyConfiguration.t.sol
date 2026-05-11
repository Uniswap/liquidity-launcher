// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LBPStrategyTestBase} from "./base/LBPStrategyTestBase.sol";

/// @notice Integration tests for LBPStrategyConfiguration
/// Branch-level revert + fuzz tests are in btt/lbpV3/definitions/setProtocolFeeController.sol
contract LBPStrategyConfiguration_Test is LBPStrategyTestBase {
    function test_protocolFeeController_setInConstructor() public {
        assertEq(strategy.protocolFeeController(), makeAddr("protocolFeeController"));
    }

    function test_storageSurvivesUpdates(address _controller, address _controller2) public {
        vm.assume(_controller != address(0) && _controller2 != address(0));

        strategy.setProtocolFeeController(_controller);

        assertEq(strategy.protocolFeeController(), _controller);

        // Update one, verify other survives
        strategy.setProtocolFeeController(_controller2);
        assertEq(strategy.protocolFeeController(), _controller2);
    }
}
