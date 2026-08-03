// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {LiquidityLauncher} from "../src/LiquidityLauncher.sol";
import {Multicall} from "../src/Multicall.sol";
import {IMulticall} from "../src/interfaces/IMulticall.sol";
import {MockCallTarget} from "./mocks/MockCallTarget.sol";

contract LiquidityLauncherCallWithValueMockTest is Test, DeployPermit2 {
    LiquidityLauncher internal launcher;
    MockCallTarget internal callTarget;

    address internal caller = makeAddr("caller");

    function setUp() public {
        launcher = new LiquidityLauncher(IAllowanceTransfer(deployPermit2()));
        callTarget = new MockCallTarget();
    }

    function test_callWithValue_forwardsValueAndCalldata() public {
        bytes memory payload = abi.encode("hello");
        bytes memory callData = abi.encodeCall(MockCallTarget.echo, (payload));

        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(Multicall.callWithValue, (address(callTarget), 1 ether, callData));

        vm.deal(caller, 1 ether);
        vm.prank(caller);
        launcher.multicall{value: 1 ether}(calls);

        assertEq(callTarget.lastCaller(), address(launcher));
        assertEq(callTarget.lastValue(), 1 ether);
        assertEq(callTarget.lastCalldata(), payload);
        assertEq(address(launcher).balance, 0);
    }

    function test_callWithValue_bubblesRevert() public {
        bytes memory callData = abi.encodeCall(MockCallTarget.revertAlways, ());

        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(Multicall.callWithValue, (address(callTarget), 1 ether, callData));

        vm.deal(caller, 1 ether);
        vm.prank(caller);
        vm.expectRevert(MockCallTarget.ExpectedRevert.selector);
        launcher.multicall{value: 1 ether}(calls);
    }

    function test_callWithValue_unspentNative_revertsWithoutSweep() public {
        bytes memory callData = abi.encodeCall(MockCallTarget.echo, (bytes("x")));

        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(Multicall.callWithValue, (address(callTarget), 1 ether, callData));

        vm.deal(caller, 1.4 ether);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(IMulticall.NativeNotSwept.selector, 0.4 ether));
        launcher.multicall{value: 1.4 ether}(calls);
    }

    function test_callWithValue_overfund_sweepsRemainder() public {
        bytes memory callData = abi.encodeCall(MockCallTarget.echo, (bytes("x")));

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(Multicall.callWithValue, (address(callTarget), 1 ether, callData));
        calls[1] = abi.encodeCall(LiquidityLauncher.sweepNative, (caller));

        vm.deal(caller, 1.4 ether);
        vm.prank(caller);
        launcher.multicall{value: 1.4 ether}(calls);

        assertEq(caller.balance, 0.4 ether);
        assertEq(address(launcher).balance, 0);
    }
}
