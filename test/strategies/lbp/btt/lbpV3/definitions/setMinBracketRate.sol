// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LBPStrategyTestBase} from "../../../base/LBPStrategyTestBase.sol";
import {ILBPStrategyConfiguration} from "src/interfaces/ILBPStrategyConfiguration.sol";
import {Ownable} from "solady/auth/Ownable.sol";

/// @title SetMinBracketRateTest
/// @notice BTT tests for LBPStrategy.setMinBracketRate
///
/// setMinBracketRate
/// ├── when caller is not owner
/// │   └── it reverts
/// └── when caller is owner
///     ├── when minBracketRate is 0
///     │   └── it reverts with InvalidMinBracketRate
///     ├── when minBracketRate > MAX_BRACKET_RATE
///     │   └── it reverts with InvalidMinBracketRate
///     └── when minBracketRate is in [1, MAX_BRACKET_RATE]
///         ├── it sets the minBracketRate
///         ├── it preserves the protocolFeeController
///         └── it emits MinBracketRateSet
contract SetMinBracketRateTest is LBPStrategyTestBase {
    function test_SetMinBracketRate_WhenCallerIsNotOwner(address _caller) public {
        vm.assume(_caller != address(this));

        vm.prank(_caller);
        vm.expectRevert(Ownable.Unauthorized.selector);
        strategy.setMinBracketRate(5000);
    }

    modifier whenCallerIsOwner() {
        _;
    }

    function test_SetMinBracketRate_WhenValueIsZero() public whenCallerIsOwner {
        vm.expectRevert(abi.encodeWithSelector(ILBPStrategyConfiguration.InvalidMinBracketRate.selector, 0));
        strategy.setMinBracketRate(0);
    }

    function test_SetMinBracketRate_WhenValueIsOverMaxBracketRate(uint24 _value) public whenCallerIsOwner {
        _value = uint24(bound(_value, strategy.MAX_BRACKET_RATE() + 1, type(uint24).max));

        vm.expectRevert(abi.encodeWithSelector(ILBPStrategyConfiguration.InvalidMinBracketRate.selector, _value));
        strategy.setMinBracketRate(_value);
    }

    modifier whenValueIsInRange() {
        _;
    }

    function test_SetMinBracketRate_WhenValid(uint24 _value) public whenCallerIsOwner whenValueIsInRange {
        _value = uint24(bound(_value, 1, strategy.MAX_BRACKET_RATE()));

        vm.expectEmit();
        emit ILBPStrategyConfiguration.MinBracketRateSet(_value);
        strategy.setMinBracketRate(_value);

        assertEq(strategy.minBracketRate(), _value);
    }

    function test_SetMinBracketRate_PreservesProtocolFeeController(uint24 _value)
        public
        whenCallerIsOwner
        whenValueIsInRange
    {
        _value = uint24(bound(_value, 1, strategy.MAX_BRACKET_RATE()));

        address controller = makeAddr("controller");
        strategy.setProtocolFeeController(controller);
        strategy.setMinBracketRate(_value);

        assertEq(strategy.protocolFeeController(), controller);
        assertEq(strategy.minBracketRate(), _value);
    }
}
