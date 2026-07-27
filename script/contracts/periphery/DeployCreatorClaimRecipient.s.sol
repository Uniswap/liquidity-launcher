// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {CreatorClaimRecipient} from "../../../src/periphery/CreatorClaimRecipient.sol";
import {DeployParameters, Parameters} from "../Parameters.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {console} from "forge-std/console.sol";

/// @title DeployCreatorClaimRecipientScript
/// @notice Deploys a CreatorClaimRecipient contract for the given chain
contract DeployCreatorClaimRecipientScript is Script, Parameters {
    function run() public returns (address creatorClaimRecipient) {
        DeployParameters memory params = getParameters(block.chainid);

        // Optionally use a salt for deployment
        bytes32 salt = bytes32(0);
        bytes memory bytecode =
            abi.encodePacked(type(CreatorClaimRecipient).creationCode, abi.encode(params.positionManager));
        bytes32 initCodeHash = keccak256(bytecode);
        address expectedAddress = Create2.computeAddress(salt, initCodeHash, DEFAULT_CREATE2_DEPLOYER);
        if (expectedAddress.code.length > 0) {
            console.log("Skipping deployment of CreatorClaimRecipient as it already exists at", expectedAddress);
            return expectedAddress;
        }

        vm.broadcast();
        creatorClaimRecipient = Create2.deploy(0, salt, bytecode);
        console.log("CreatorClaimRecipient deployed to:", creatorClaimRecipient);
        return creatorClaimRecipient;
    }
}
