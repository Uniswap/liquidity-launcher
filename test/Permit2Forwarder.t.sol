// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {Permit2Forwarder} from "../src/Permit2Forwarder.sol";
import {Permit2SignatureHelpers} from "./shared/Permit2SignatureHelpers.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";

contract Permit2ForwarderTest is Test, DeployPermit2, Permit2SignatureHelpers {
    Permit2Forwarder permit2Forwarder;
    IAllowanceTransfer permit2;

    uint160 amount0 = 10e18;
    // the expiration of the allowance is large
    uint48 expiration = uint48(block.timestamp + 10e18);
    uint48 nonce = 0;

    bytes32 PERMIT2_DOMAIN_SEPARATOR;

    uint256 alicePrivateKey;
    address alice;

    MockERC20 token0;

    function setUp() public {
        permit2 = IAllowanceTransfer(deployPermit2());
        permit2Forwarder = new Permit2Forwarder(permit2);
        PERMIT2_DOMAIN_SEPARATOR = permit2.DOMAIN_SEPARATOR();

        alicePrivateKey = 0x12341234;
        alice = vm.addr(alicePrivateKey);

        // mock token
        token0 = new MockERC20("Token 0", "T0", 10e18, address(this));
    }

    function test_permit_single_succeeds() public {
        IAllowanceTransfer.PermitSingle memory permit =
            defaultERC20PermitAllowance(address(token0), amount0, expiration, nonce);
        bytes memory sig = getPermitSignature(permit, alicePrivateKey, PERMIT2_DOMAIN_SEPARATOR);

        permit2Forwarder.permit(alice, permit, sig);

        (uint160 _amount, uint48 _expiration, uint48 _nonce) = permit2.allowance(alice, address(token0), address(this));
        assertEq(_amount, amount0);
        assertEq(_expiration, expiration);
        assertEq(_nonce, nonce + 1); // the nonce was incremented
    }

    // forge-config: default.isolate = true
    // forge-config: ci.isolate = true
    function test_permit_single_gas() public {
        IAllowanceTransfer.PermitSingle memory permit =
            defaultERC20PermitAllowance(address(token0), amount0, expiration, nonce);
        bytes memory sig = getPermitSignature(permit, alicePrivateKey, PERMIT2_DOMAIN_SEPARATOR);

        permit2Forwarder.permit(alice, permit, sig);
        vm.snapshotGasLastCall("permit");
    }
}
