// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title MockCallTarget
/// @notice Records forwarded calls for `callWithValue` tests.
contract MockCallTarget {
    address public lastCaller;
    uint256 public lastValue;
    bytes public lastCalldata;

    error ExpectedRevert();

    receive() external payable {}

    function echo(bytes calldata data) external payable returns (bytes memory) {
        lastCaller = msg.sender;
        lastValue = msg.value;
        lastCalldata = data;
        return data;
    }

    function revertAlways() external payable {
        revert ExpectedRevert();
    }
}
