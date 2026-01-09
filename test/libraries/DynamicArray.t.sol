// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DynamicArray} from "../../src/libraries/DynamicArray.sol";

contract DynamicArrayTest is Test {
    using DynamicArray for bytes[];

    function test_init_gas() public {
        vm.startSnapshotGas("init");
        bytes[] memory params = DynamicArray.init();
        vm.stopSnapshotGas();
        assertEq(params.length, 0);
    }

    function test_append_single_succeeds_gas() public {
        bytes[] memory params = DynamicArray.init();
        bytes memory param = abi.encode(uint256(1));
        vm.startSnapshotGas("append single");
        params = DynamicArray.append(params, param);
        vm.stopSnapshotGas();
        assertEq(params.length, 1);
        assertEq(params[0], param);
    }

    function test_append_single_fuzz(bytes memory param) public {
        bytes[] memory params = DynamicArray.init();
        params = DynamicArray.append(params, param);
        assertEq(params.length, 1);
        assertEq(params[0], param);
    }

    function test_append_multiple_succeeds() public {
        bytes[] memory params = DynamicArray.init();
        for (uint256 i = 0; i < DynamicArray.MAX_PARAMS_SIZE; i++) {
            bytes memory param = abi.encode(i);
            params = DynamicArray.append(params, param);
            assertEq(params.length, i + 1);
            assertEq(params[i], param);
        }
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_append_overflow_reverts() public {
        bytes[] memory params = DynamicArray.init();
        for (uint256 i = 0; i < DynamicArray.MAX_PARAMS_SIZE; i++) {
            params = DynamicArray.append(params, abi.encode(i));
        }
        vm.expectRevert(DynamicArray.LengthOverflow.selector);
        DynamicArray.append(params, abi.encode(uint256(DynamicArray.MAX_PARAMS_SIZE)));
    }

    function test_fuzz_append(uint8 numParams) public {
        vm.assume(numParams > 0 && numParams <= DynamicArray.MAX_PARAMS_SIZE);
        bytes[] memory params = DynamicArray.init();
        for (uint256 i = 0; i < numParams; i++) {
            params = DynamicArray.append(params, abi.encode(i));
        }
    }
}
