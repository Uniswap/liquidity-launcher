// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LBPStrategyTestBase} from "./base/LBPStrategyTestBase.sol";
import {ILBPStrategy} from "src/interfaces/ILBPStrategy.sol";

/// @notice Integration and edge case tests for owner controls
/// Branch-level revert + fuzz tests are in btt/lbpV3/definitions/setProtocolFeeController.sol and setMinSplitForLp.sol
contract LBPStrategy_OwnerControls_Test is LBPStrategyTestBase {
    function test_protocolFeeController_defaultsToZero() public view {
        (address controller,) = strategy.ownerControlledParams();
        assertEq(controller, address(0));
    }

    function test_minSplitForLp_defaultsToZero() public view {
        (, uint24 minSplit) = strategy.ownerControlledParams();
        assertEq(minSplit, 0);
    }

    function test_packedStorageSurvivesUpdates() public {
        address controller = makeAddr("controller");
        strategy.setProtocolFeeController(controller);
        strategy.setMinSplitForLp(7777);

        (address readCtrl, uint24 readSplit) = strategy.ownerControlledParams();
        assertEq(readCtrl, controller);
        assertEq(readSplit, 7777);

        // Update one, verify other survives
        strategy.setProtocolFeeController(makeAddr("ctrl2"));
        (readCtrl, readSplit) = strategy.ownerControlledParams();
        assertEq(readCtrl, makeAddr("ctrl2"));
        assertEq(readSplit, 7777);
    }
}
