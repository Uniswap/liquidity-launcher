// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ParamsBuilderV2} from "src/libraries/ParamsBuilderV2.sol";

contract MockParamsBuilderV2 {
    using ParamsBuilderV2 for bytes[];

    function init() external returns (bytes[] memory) {
        return ParamsBuilderV2.init();
    }

    function append(bytes[] memory params, bytes memory param) external returns (bytes[] memory) {
        return params.append(param);
    }

    function merge(bytes[] memory params, bytes[] memory otherParams) external returns (bytes[] memory) {
        return params.merge(otherParams);
    }

    function truncate(bytes[] memory params) external view returns (bytes[] memory) {
        return params.truncate();
    }

    function getLength() external view returns (uint8) {
        return ParamsBuilderV2.getLength();
    }
}

contract ParamsBuilderV2Test is Test {
    MockParamsBuilderV2 mockParamsBuilder;

    function setUp() public {
        mockParamsBuilder = new MockParamsBuilderV2();
    }

    function test_init_succeeds_gas() public {
        bytes[] memory params = mockParamsBuilder.init();
        vm.snapshotGasLastCall("init");
        assertEq(params.length, ParamsBuilderV2.MAX_PARAMS);
        assertEq(mockParamsBuilder.getLength(), 0);
    }

    function test_append_single_succeeds_gas() public {
        bytes[] memory params = mockParamsBuilder.init();
        bytes memory param = abi.encode(uint256(1));
        params = mockParamsBuilder.append(params, param);
        vm.snapshotGasLastCall("append single");
        assertEq(mockParamsBuilder.getLength(), 1);
        assertEq(params[0], param);
    }

    function test_append_single_fuzz(bytes memory param) public {
        bytes[] memory params = mockParamsBuilder.init();
        params = mockParamsBuilder.append(params, param);
        vm.snapshotGasLastCall("append single");
    }

    function test_append_multiple_succeeds() public {
        bytes[] memory params = mockParamsBuilder.init();
        for (uint256 i = 0; i < 10; i++) {
            bytes memory param = abi.encode(i);
            params = mockParamsBuilder.append(params, param);
            assertEq(mockParamsBuilder.getLength(), i + 1);
            assertEq(params[i], param);
        }
    }

    function test_append_overflow_reverts() public {
        bytes[] memory params = mockParamsBuilder.init();
        for (uint256 i = 0; i < ParamsBuilderV2.MAX_PARAMS; i++) {
            params = mockParamsBuilder.append(params, abi.encode(i));
        }
        vm.expectRevert(ParamsBuilderV2.LengthOverflow.selector);
        mockParamsBuilder.append(params, abi.encode(uint256(ParamsBuilderV2.MAX_PARAMS)));
    }

    function test_merge_succeeds(uint8 initialLength, uint8 otherLength) public {
        vm.assume(initialLength > 0 && initialLength < ParamsBuilderV2.MAX_PARAMS);
        otherLength = uint8(_bound(otherLength, 1, ParamsBuilderV2.MAX_PARAMS - initialLength));
        bytes[] memory params = mockParamsBuilder.init();
        for (uint256 i = 0; i < initialLength; i++) {
            params = mockParamsBuilder.append(params, abi.encodePacked("initial", i));
        }

        bytes[] memory otherParams = new bytes[](otherLength);
        for (uint256 i = 0; i < otherLength; i++) {
            otherParams[i] = abi.encodePacked("other", i);
        }
        params = mockParamsBuilder.merge(params, otherParams);
        assertEq(mockParamsBuilder.getLength(), initialLength + otherLength);
        for (uint256 i = 0; i < initialLength; i++) {
            assertEq(params[i], abi.encodePacked("initial", i));
        }
        for (uint256 i = 0; i < otherLength; i++) {
            assertEq(params[initialLength + i], abi.encodePacked("other", i));
        }
    }

    function test_merge_overflow_revert_fuzz(uint8 otherLength) public {
        vm.assume(otherLength > ParamsBuilderV2.MAX_PARAMS);
        bytes[] memory params = mockParamsBuilder.init();
        vm.expectRevert(ParamsBuilderV2.LengthOverflow.selector);
        mockParamsBuilder.merge(params, new bytes[](otherLength));
    }

    function test_merge_succeeds_fuzz(bytes[] memory otherParams) public {
        vm.assume(otherParams.length > 0 && otherParams.length <= ParamsBuilderV2.MAX_PARAMS);
        bytes[] memory params = mockParamsBuilder.init();
        params = mockParamsBuilder.merge(params, otherParams);
        vm.snapshotGasLastCall("merge");
    }

    function test_truncate_empty_succeeds() public {
        bytes[] memory params = mockParamsBuilder.init();
        params = mockParamsBuilder.truncate(params);
        assertEq(params.length, 0);
    }

    function test_truncate_partial_succeeds() public {
        bytes[] memory params = mockParamsBuilder.init();
        for (uint256 i = 0; i < 5; i++) {
            params = mockParamsBuilder.append(params, abi.encode(i));
        }
        params = mockParamsBuilder.truncate(params);
        assertEq(params.length, 5);
        for (uint256 i = 0; i < 5; i++) {
            assertEq(params[i], abi.encode(i));
        }
    }

    function test_truncate_full_succeeds() public {
        bytes[] memory params = mockParamsBuilder.init();
        for (uint256 i = 0; i < ParamsBuilderV2.MAX_PARAMS; i++) {
            params = mockParamsBuilder.append(params, abi.encode(i));
        }
        params = mockParamsBuilder.truncate(params);
        assertEq(params.length, ParamsBuilderV2.MAX_PARAMS);
    }

    function test_fuzz_append_and_truncate(uint8 numParams) public {
        vm.assume(numParams > 0 && numParams <= ParamsBuilderV2.MAX_PARAMS);
        bytes[] memory params = mockParamsBuilder.init();
        for (uint256 i = 0; i < numParams; i++) {
            params = mockParamsBuilder.append(params, abi.encode(i));
        }
        assertEq(mockParamsBuilder.getLength(), numParams);
        params = mockParamsBuilder.truncate(params);
        assertEq(params.length, numParams);
        for (uint256 i = 0; i < numParams; i++) {
            assertEq(params[i], abi.encode(i));
        }
    }
}

