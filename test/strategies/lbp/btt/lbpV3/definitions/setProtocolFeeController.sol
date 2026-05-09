// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LBPStrategyTestBase} from "../../../base/LBPStrategyTestBase.sol";
import {ILBPStrategy} from "src/interfaces/ILBPStrategy.sol";
import {Ownable} from "solady/auth/Ownable.sol";

/// @title SetProtocolFeeControllerTest
/// @notice BTT tests for LBPStrategy.setProtocolFeeController
///
/// setProtocolFeeController
/// ├── when caller is not owner
/// │   └── it reverts
/// └── when caller is owner
///     ├── when protocolFeeController is address(0)
///     │   └── it reverts with InvalidProtocolFeeController
///     └── when protocolFeeController is not address(0)
///         ├── it sets the protocolFeeController
///         └── it emits ProtocolFeeControllerSet
contract SetProtocolFeeControllerTest is LBPStrategyTestBase {
    function test_SetProtocolFeeController_WhenCallerIsNotOwner(address _caller) public {
        vm.assume(_caller != address(this));

        vm.prank(_caller);
        vm.expectRevert(Ownable.Unauthorized.selector);
        strategy.setProtocolFeeController(makeAddr("controller"));
    }

    modifier whenCallerIsOwner_setFeeController() {
        _;
    }

    function test_SetProtocolFeeController_WhenAddressIsZero() public whenCallerIsOwner_setFeeController {
        vm.expectRevert(ILBPStrategy.InvalidProtocolFeeController.selector);
        strategy.setProtocolFeeController(address(0));
    }

    modifier whenAddressIsNotZero_setFeeController() {
        _;
    }

    function test_SetProtocolFeeController_WhenValid(address _controller)
        public
        whenCallerIsOwner_setFeeController
        whenAddressIsNotZero_setFeeController
    {
        vm.assume(_controller != address(0));

        vm.expectEmit();
        emit ILBPStrategy.ProtocolFeeControllerSet(_controller);
        strategy.setProtocolFeeController(_controller);

        assertEq(strategy.protocolFeeController(), _controller);
    }
}
