// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DynamicArray} from "../../src/libraries/DynamicArray.sol";

contract DynamicArrayTestHelper {
    using DynamicArray for bytes[];

    /// @notice Initializes the parameters, allocating memory for maximum number of params
    function init() public returns (bytes[] memory params) {
        return DynamicArray.init();
    }

    function getLength() public view returns (uint256 length) {
        return DynamicArray.getLength();
    }

    /// @notice Appends a new parameter to the params array
    function append(bytes[] memory params, bytes memory param) public returns (bytes[] memory) {
        return params.append(param);
    }

    /// @notice Truncates the params array to its actual length
    function truncate(bytes[] memory params) public view returns (bytes[] memory) {
        return params.truncate();
    }
}

contract DynamicArrayTest is Test {
    using DynamicArray for bytes[];
    DynamicArrayTestHelper internal testHelper;

    function setUp() public {
        testHelper = new DynamicArrayTestHelper();
    }

    function test_init_gas() public {
        bytes[] memory params = testHelper.init();
        vm.snapshotGasLastCall("init");
        assertEq(testHelper.getLength(), 0);
        assertEq(params.length, DynamicArray.MAX_PARAMS_SIZE);
    }

    function test_append_single_succeeds_gas() public {
        bytes[] memory params = testHelper.init();
        bytes memory param = abi.encode(uint256(1));
        params = testHelper.append(params, param);
        vm.snapshotGasLastCall("append single");
        assertEq(testHelper.getLength(), 1);
        assertEq(params[0], param);
    }

    function test_append_single_fuzz(bytes memory param) public {
        bytes[] memory params = testHelper.init();
        params = testHelper.append(params, param);
        vm.snapshotGasLastCall("append single");
    }

    function test_append_multiple_succeeds() public {
        bytes[] memory params = testHelper.init();
        for (uint256 i = 0; i < DynamicArray.MAX_PARAMS_SIZE; i++) {
            bytes memory param = abi.encode(i);
            params = testHelper.append(params, param);
            assertEq(testHelper.getLength(), i + 1);
            assertEq(params[i], param);
        }
    }

    function test_append_overflow_reverts() public {
        bytes[] memory params = testHelper.init();
        for (uint256 i = 0; i < DynamicArray.MAX_PARAMS_SIZE; i++) {
            params = testHelper.append(params, abi.encode(i));
        }
        vm.expectRevert(DynamicArray.LengthOverflow.selector);
        testHelper.append(params, abi.encode(uint256(DynamicArray.MAX_PARAMS_SIZE)));
    }

    function test_truncate_empty_succeeds() public {
        bytes[] memory params = testHelper.init();
        params = testHelper.truncate(params);
        assertEq(params.length, 0);
    }

    function test_truncate_partial_succeeds() public {
        bytes[] memory params = testHelper.init();
        for (uint256 i = 0; i < 5; i++) {
            params = testHelper.append(params, abi.encode(i));
        }
        params = testHelper.truncate(params);
        assertEq(params.length, 5);
        for (uint256 i = 0; i < 5; i++) {
            assertEq(params[i], abi.encode(i));
        }
    }

    function test_truncate_full_succeeds() public {
        bytes[] memory params = testHelper.init();
        for (uint256 i = 0; i < DynamicArray.MAX_PARAMS_SIZE; i++) {
            params = testHelper.append(params, abi.encode(i));
        }
        params = testHelper.truncate(params);
        assertEq(params.length, DynamicArray.MAX_PARAMS_SIZE);
    }

    function test_fuzz_append_and_truncate(uint8 numParams) public {
        vm.assume(numParams > 0 && numParams <= DynamicArray.MAX_PARAMS_SIZE);
        bytes[] memory params = testHelper.init();
        for (uint256 i = 0; i < numParams; i++) {
            params = testHelper.append(params, abi.encode(i));
        }
        assertEq(testHelper.getLength(), numParams);
        params = testHelper.truncate(params);
        assertEq(params.length, numParams);
        for (uint256 i = 0; i < numParams; i++) {
            assertEq(params[i], abi.encode(i));
        }
    }
}
