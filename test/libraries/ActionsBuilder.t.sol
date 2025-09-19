// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ActionsBuilder} from "../../src/libraries/ActionsBuilder.sol";
import {FullRangeParams, OneSidedParams} from "../../src/types/PositionTypes.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickBounds} from "../../src/types/PositionTypes.sol";

// Test helper contract to expose internal library functions for testing
contract ActionsBuilderTestHelper {
    function buildFullRangeActions() external pure returns (bytes memory) {
        return ActionsBuilder.buildFullRangeActions();
    }

    function buildOneSidedActions(bytes memory existingActions) external pure returns (bytes memory) {
        return ActionsBuilder.buildOneSidedActions(existingActions);
    }
}

contract ActionsBuilderTest is Test {
    ActionsBuilderTestHelper testHelper;

    function setUp() public {
        testHelper = new ActionsBuilderTestHelper();
    }

    function test_buildFullRangeActions_succeeds() public view {
        bytes memory actions = testHelper.buildFullRangeActions();
        assertEq(actions.length, 5);
    }

    function test_buildOneSidedActions_revertsWithInvalidActionsLength() public {
        vm.expectRevert(abi.encodeWithSelector(ActionsBuilder.InvalidActionsLength.selector, 1));
        testHelper.buildOneSidedActions(new bytes(1));
    }

    function test_buildOneSidedActions_succeeds() public view {
        bytes memory actions = testHelper.buildFullRangeActions();
        bytes memory oneSidedActions = testHelper.buildOneSidedActions(actions);
        assertEq(oneSidedActions.length, 8);
    }
}
