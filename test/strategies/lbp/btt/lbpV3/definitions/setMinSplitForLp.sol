// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LBPStrategyTestBase} from "../../../base/LBPStrategyTestBase.sol";
import {ILBPStrategy} from "src/interfaces/ILBPStrategy.sol";
import {Ownable} from "solady/auth/Ownable.sol";

/// @title SetMinSplitForLpTest
/// @notice BTT tests for LBPStrategy.setMinSplitForLp
///
/// setMinSplitForLp
/// ├── when caller is not owner
/// │   └── it reverts
/// └── when caller is owner
///     ├── when minSplitForLp is 0
///     │   └── it reverts with InvalidMinSplitForLp
///     ├── when minSplitForLp > 10_000
///     │   └── it reverts with InvalidMinSplitForLp
///     └── when minSplitForLp is in [1, 10_000]
///         ├── it sets the minSplitForLp
///         ├── it preserves the protocolFeeController
///         └── it emits MinSplitForLpSet
contract SetMinSplitForLpTest is LBPStrategyTestBase {
    function test_SetMinSplitForLp_WhenCallerIsNotOwner(address _caller) public {
        vm.assume(_caller != address(this));

        vm.prank(_caller);
        vm.expectRevert(Ownable.Unauthorized.selector);
        strategy.setMinSplitForLp(5000);
    }

    modifier whenCallerIsOwner_setMinSplit() {
        _;
    }

    function test_SetMinSplitForLp_WhenValueIsZero() public whenCallerIsOwner_setMinSplit {
        vm.expectRevert(ILBPStrategy.InvalidMinSplitForLp.selector);
        strategy.setMinSplitForLp(0);
    }

    function test_SetMinSplitForLp_WhenValueIsOverMAX_BPS(uint24 _value) public whenCallerIsOwner_setMinSplit {
        _value = uint24(bound(_value, 10_001, type(uint24).max));

        vm.expectRevert(ILBPStrategy.InvalidMinSplitForLp.selector);
        strategy.setMinSplitForLp(_value);
    }

    modifier whenValueIsInRange() {
        _;
    }

    function test_SetMinSplitForLp_WhenValid(uint24 _value) public whenCallerIsOwner_setMinSplit whenValueIsInRange {
        _value = uint24(bound(_value, 1, 10_000));

        vm.expectEmit();
        emit ILBPStrategy.MinSplitForLpSet(_value);
        strategy.setMinSplitForLp(_value);

        (, uint24 stored) = strategy.ownerControlledParams();
        assertEq(stored, _value);
    }

    function test_SetMinSplitForLp_PreservesProtocolFeeController(uint24 _value, address _controller)
        public
        whenCallerIsOwner_setMinSplit
        whenValueIsInRange
    {
        _value = uint24(bound(_value, 1, 10_000));
        vm.assume(_controller != address(0));

        strategy.setProtocolFeeController(_controller);
        strategy.setMinSplitForLp(_value);

        (address readCtrl, uint24 readSplit) = strategy.ownerControlledParams();
        assertEq(readCtrl, _controller);
        assertEq(readSplit, _value);
    }
}
