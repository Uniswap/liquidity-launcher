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

    function test_packedStorageSurvivesUpdates(address _controller, uint24 _minSplit, address _controller2) public {
        vm.assume(_controller != address(0) && _controller2 != address(0));
        _minSplit = uint24(bound(_minSplit, 1, 10_000));

        strategy.setProtocolFeeController(_controller);
        strategy.setMinSplitForLp(_minSplit);

        (address readCtrl, uint24 readSplit) = strategy.ownerControlledParams();
        assertEq(readCtrl, _controller);
        assertEq(readSplit, _minSplit);

        // Update one, verify other survives
        strategy.setProtocolFeeController(_controller2);
        (readCtrl, readSplit) = strategy.ownerControlledParams();
        assertEq(readCtrl, _controller2);
        assertEq(readSplit, _minSplit);
    }
}
