// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {LiquidityLauncher} from "../../../../src/LiquidityLauncher.sol";
import {Multicall} from "../../../../src/Multicall.sol";
import {MockCallTarget} from "../../../mocks/MockCallTarget.sol";

/// @notice Shared fixture for Multicall BTT unit tests.
abstract contract MulticallTestBase is Test, DeployPermit2 {
    LiquidityLauncher internal launcher;
    MockCallTarget internal callTarget;

    address internal caller = makeAddr("caller");

    function setUp() public virtual {
        launcher = new LiquidityLauncher(IAllowanceTransfer(deployPermit2()));
        callTarget = new MockCallTarget();
    }

    function _encodeCallWithValue(address target, uint256 value, bytes memory callData)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeCall(Multicall.callWithValue, (target, value, callData));
    }

    function _multicallAsCaller(bytes[] memory calls, uint256 value) internal {
        vm.deal(caller, value);
        vm.prank(caller);
        launcher.multicall{value: value}(calls);
    }
}
