// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {DeployParameters, Parameters} from "../Parameters.sol";
import {UERC20BeneficiaryVault} from "../../../src/periphery/UERC20BeneficiaryVault.sol";
import {console} from "forge-std/console.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

/// @title DeployUERC20BeneficiaryVaultScript
contract DeployUERC20BeneficiaryVaultScript is Script, Parameters {
    function run() public returns (address uerc20BeneficiaryVault) {
        DeployParameters memory params = getParameters(block.chainid);

        // Optionally use a salt for deployment
        bytes32 salt = vm.envOr("GLOBAL_SALT", bytes32(0));

        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(UERC20BeneficiaryVault).creationCode,
                abi.encode(params.positionManager, getTokenJar(block.chainid), DEFAULT_BURN_ADDRESS)
            )
        );
        address expectedAddress = Create2.computeAddress(salt, initCodeHash, DEFAULT_CREATE2_DEPLOYER);
        if (expectedAddress.code.length > 0) {
            console.log("Skipping deployment of UERC20BeneficiaryVault as it already exists at", expectedAddress);
            return expectedAddress;
        }

        vm.broadcast();
        uerc20BeneficiaryVault = Create2.deploy(
            0,
            salt,
            abi.encodePacked(
                type(UERC20BeneficiaryVault).creationCode,
                abi.encode(params.positionManager, getTokenJar(block.chainid), DEFAULT_BURN_ADDRESS)
            )
        );
        console.log("UERC20BeneficiaryVault deployed to:", uerc20BeneficiaryVault);
        return uerc20BeneficiaryVault;
    }
}
