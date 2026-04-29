// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LBPStrategyTestBase} from "./base/LBPStrategyTestBase.sol";
import {ILBPStrategyConfiguration} from "src/interfaces/ILBPStrategyConfiguration.sol";

/// @notice Integration and edge case tests for owner controls
/// Branch-level revert + fuzz tests are in btt/lbpV3/definitions/setProtocolFeeController.sol and setMinSplitForLp.sol
contract LBPStrategy_OwnerControls_Test is LBPStrategyTestBase {
    function test_protocolFeeController_setInConstructor() public view {
        assertNotEq(strategy.protocolFeeController(), address(0));
    }

    function test_minSplitForLp_setInConstructor() public view {
        assertGt(strategy.minSplitForLp(), 0);
    }

    function test_storageUpdatesAreIndependent(address _controller, uint24 _minSplit, address _controller2) public {
        vm.assume(_controller != address(0) && _controller2 != address(0));
        _minSplit = uint24(bound(_minSplit, 1, 10_000));

        strategy.setProtocolFeeController(_controller);
        strategy.setMinSplitForLp(_minSplit);

        assertEq(strategy.protocolFeeController(), _controller);
        assertEq(strategy.minSplitForLp(), _minSplit);

        // Update one, verify other survives
        strategy.setProtocolFeeController(_controller2);
        assertEq(strategy.protocolFeeController(), _controller2);
        assertEq(strategy.minSplitForLp(), _minSplit);
    }
}
