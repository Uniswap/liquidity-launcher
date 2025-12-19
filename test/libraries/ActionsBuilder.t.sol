// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ActionsBuilder} from "src/libraries/ActionsBuilder.sol";

contract ActionsBuilderTest is Test {
    using ActionsBuilder for bytes;

    function test_addMint_succeeds() public view {
        bytes memory actions = ActionsBuilder.init();
        actions = actions.addMint(actions);
        assertEq(actions.length, 1);
    }

    function test_addSettle_succeeds() public view {
        bytes memory actions = ActionsBuilder.init();
        actions = actions.addSettle(actions);
        assertEq(actions.length, 1);
    }

    function test_addTakePair_succeeds() public view {
        bytes memory actions = ActionsBuilder.init();
        actions = actions.addTakePair(actions);
        assertEq(actions.length, 1);
    }

    function test_addMint_addSettle_addTakePair_succeeds() public view {
        bytes memory actions = ActionsBuilder.init();
        actions = actions.addMint(actions);
        actions = actions.addSettle(actions);
        actions = actions.addTakePair(actions);
        assertEq(actions.length, 3);
    }
}
