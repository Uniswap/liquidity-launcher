// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ActionsBuilder} from "src/libraries/ActionsBuilder.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickBounds} from "src/types/PositionTypes.sol";

// Test helper contract to expose internal library functions for testing
contract ActionsBuilderTestHelper {
    function init() external pure returns (bytes memory) {
        return ActionsBuilder.init();
    }

    function addMint(bytes memory existingActions) external pure returns (bytes memory) {
        return ActionsBuilder.addMint(existingActions);
    }

    function addSettle(bytes memory existingActions) external pure returns (bytes memory) {
        return ActionsBuilder.addSettle(existingActions);
    }

    function addTakePair(bytes memory existingActions) external pure returns (bytes memory) {
        return ActionsBuilder.addTakePair(existingActions);
    }
}

contract ActionsBuilderTest is Test {
    ActionsBuilderTestHelper testHelper;
    using ActionsBuilder for *;

    function setUp() public {
        testHelper = new ActionsBuilderTestHelper();
    }

    function test_addMint_revertsWithInvalidActionsLength() public {
        vm.expectRevert(abi.encodeWithSelector(ActionsBuilder.InvalidActionsLength.selector, 1));
        testHelper.addMint(new bytes(1));
    }

    function test_addMint_succeeds() public view {
        bytes memory actions = testHelper.init().addMint();
        assertEq(actions.length, 1);
    }
}
