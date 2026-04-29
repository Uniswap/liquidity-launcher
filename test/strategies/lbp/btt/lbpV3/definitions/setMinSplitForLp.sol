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
///     ├── when minBracketRate > MAX_BRACKET_RATE (1e7)
///     │   └── it reverts with InvalidMinBracketRate
///     └── when minBracketRate is in [1, 1e7]
///         ├── it sets the minBracketRate
///         ├── it preserves the protocolFeeController
///         └── it emits MinBracketRateSet
contract SetMinBracketRateTest is LBPStrategyTestBase {
    function test_SetMinBracketRate_WhenCallerIsNotOwner(address _caller) public {
        vm.assume(_caller != address(this));

        vm.prank(_caller);
        vm.expectRevert(Ownable.Unauthorized.selector);
        strategy.setMinBracketRate(5e6);
    }

    modifier whenCallerIsOwner_setMinBracketRate() {
        _;
    }

    function test_SetMinBracketRate_WhenValueIsZero() public whenCallerIsOwner_setMinBracketRate {
        vm.expectRevert(abi.encodeWithSelector(ILBPStrategyConfiguration.InvalidMinBracketRate.selector, 0));
        strategy.setMinBracketRate(0);
    }

    function test_SetMinBracketRate_WhenValueIsOverMax(uint24 _value) public whenCallerIsOwner_setMinBracketRate {
        _value = uint24(bound(_value, 1e7 + 1, type(uint24).max));

        vm.expectRevert(abi.encodeWithSelector(ILBPStrategyConfiguration.InvalidMinBracketRate.selector, _value));
        strategy.setMinBracketRate(_value);
    }

    modifier whenValueIsInRange() {
        _;
    }

    function test_SetMinBracketRate_WhenValid(uint24 _value)
        public
        whenCallerIsOwner_setMinBracketRate
        whenValueIsInRange
    {
        _value = uint24(bound(_value, 1, 1e7));

        vm.expectEmit();
        emit ILBPStrategyConfiguration.MinBracketRateSet(_value);
        strategy.setMinBracketRate(_value);

        assertEq(strategy.minBracketRate(), _value);
    }

    function test_SetMinBracketRate_PreservesProtocolFeeController(uint24 _value, address _controller)
        public
        whenCallerIsOwner_setMinBracketRate
        whenValueIsInRange
    {
        _value = uint24(bound(_value, 1, 1e7));
        vm.assume(_controller != address(0));

        strategy.setProtocolFeeController(_controller);
        strategy.setMinBracketRate(_value);

        assertEq(strategy.protocolFeeController(), _controller);
        assertEq(strategy.minBracketRate(), _value);
    }
}
