// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {DeployParameters, Parameters} from "../Parameters.sol";
import {BeneficiaryVault} from "../../../src/periphery/BeneficiaryVault.sol";
import {console} from "forge-std/console.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

/// @title DeployBeneficiaryVaultScript
contract DeployBeneficiaryVaultScript is Script, Parameters {
    function run() public returns (address beneficiaryVault) {
        DeployParameters memory params = getParameters(block.chainid);

        // Optionally use a salt for deployment
        bytes32 salt = bytes32(0);
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(BeneficiaryVault).creationCode,
                abi.encode(params.positionManager, getTokenJar(block.chainid), DEFAULT_BURN_ADDRESS)
            )
        );
        address expectedAddress = Create2.computeAddress(salt, initCodeHash, DEFAULT_CREATE2_DEPLOYER);
        if (expectedAddress.code.length > 0) {
            console.log("Skipping deployment of BeneficiaryVault as it already exists at", expectedAddress);
            return expectedAddress;
        }

        vm.broadcast();
        address beneficiaryVault = Create2.deploy(
            0,
            salt,
            abi.encodePacked(
                type(BeneficiaryVault).creationCode,
                abi.encode(params.positionManager, getTokenJar(block.chainid), DEFAULT_BURN_ADDRESS)
            )
        );
        console.log("BeneficiaryVault deployed to:", beneficiaryVault);
        return beneficiaryVault;
    }
}
