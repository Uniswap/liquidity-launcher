// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MulticallTestBase} from "../base/MulticallTestBase.sol";
import {LiquidityLauncher} from "../../../../src/LiquidityLauncher.sol";
import {IMulticall} from "../../../../src/interfaces/IMulticall.sol";
import {MockCallTarget} from "../../../mocks/MockCallTarget.sol";

/// @title CallWithValueTest
/// @notice BTT unit tests for Multicall.callWithValue
///
/// multicall
/// └── callWithValue
///     ├── when the target call succeeds
///     │   ├── it forwards value from the launcher balance
///     │   ├── it forwards calldata to the target
///     │   └── it leaves the launcher with zero native
///     ├── when the target call reverts
///     │   └── it bubbles the revert through multicall
///     ├── when the batch carries more native than callWithValue spends
///     │   └── it reverts with NativeNotSwept
///     └── when the batch overfunds but ends with sweepNative
///         └── it returns the remainder to the recipient
contract CallWithValueTest is MulticallTestBase {
    function test_WhenTargetCallSucceeds_forwardsValueFromLauncherBalance() public {
        bytes memory callData = abi.encodeCall(MockCallTarget.echo, (abi.encode("hello")));

        bytes[] memory calls = new bytes[](1);
        calls[0] = _encodeCallWithValue(address(callTarget), 1 ether, callData);

        _multicallAsCaller(calls, 1 ether);

        assertEq(callTarget.lastValue(), 1 ether);
    }

    function test_WhenTargetCallSucceeds_forwardsCalldataToTarget() public {
        bytes memory payload = abi.encode("hello");
        bytes memory callData = abi.encodeCall(MockCallTarget.echo, (payload));

        bytes[] memory calls = new bytes[](1);
        calls[0] = _encodeCallWithValue(address(callTarget), 1 ether, callData);

        _multicallAsCaller(calls, 1 ether);

        assertEq(callTarget.lastCaller(), address(launcher));
        assertEq(callTarget.lastCalldata(), payload);
    }

    function test_WhenTargetCallSucceeds_leavesLauncherWithZeroNative() public {
        bytes memory callData = abi.encodeCall(MockCallTarget.echo, (abi.encode("hello")));

        bytes[] memory calls = new bytes[](1);
        calls[0] = _encodeCallWithValue(address(callTarget), 1 ether, callData);

        _multicallAsCaller(calls, 1 ether);

        assertEq(address(launcher).balance, 0);
    }

    function test_WhenTargetCallReverts_bubblesRevertThroughMulticall() public {
        bytes memory callData = abi.encodeCall(MockCallTarget.revertAlways, ());

        bytes[] memory calls = new bytes[](1);
        calls[0] = _encodeCallWithValue(address(callTarget), 1 ether, callData);

        vm.deal(caller, 1 ether);
        vm.prank(caller);
        vm.expectRevert(MockCallTarget.ExpectedRevert.selector);
        launcher.multicall{value: 1 ether}(calls);
    }

    function test_WhenBatchCarriesMoreNativeThanCallWithValueSpends_revertsWithNativeNotSwept() public {
        bytes memory callData = abi.encodeCall(MockCallTarget.echo, (bytes("x")));

        bytes[] memory calls = new bytes[](1);
        calls[0] = _encodeCallWithValue(address(callTarget), 1 ether, callData);

        vm.deal(caller, 1.4 ether);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(IMulticall.NativeNotSwept.selector, 0.4 ether));
        launcher.multicall{value: 1.4 ether}(calls);
    }

    function test_WhenBatchOverfundsButEndsWithSweepNative_returnsRemainderToRecipient() public {
        bytes memory callData = abi.encodeCall(MockCallTarget.echo, (bytes("x")));

        bytes[] memory calls = new bytes[](2);
        calls[0] = _encodeCallWithValue(address(callTarget), 1 ether, callData);
        calls[1] = abi.encodeCall(LiquidityLauncher.sweepNative, (caller));

        _multicallAsCaller(calls, 1.4 ether);

        assertEq(caller.balance, 0.4 ether);
        assertEq(address(launcher).balance, 0);
    }
}
