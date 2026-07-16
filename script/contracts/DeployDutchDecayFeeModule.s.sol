// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {DutchDecayFeeModule} from "../../src/periphery/modules/DutchDecayFeeModule.sol";
import {Parameters} from "./Parameters.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

/// @title DeployDutchDecayFeeModuleScript
/// @notice Deploys the DutchDecayFeeModule singleton
contract DeployDutchDecayFeeModuleScript is Script, Parameters {
    function run() public returns (address) {
        bytes32 initCodeHash = keccak256(abi.encodePacked(type(DutchDecayFeeModule).creationCode));
        address expectedAddress = Create2.computeAddress(bytes32(0), initCodeHash, DEFAULT_CREATE2_DEPLOYER);
        if (expectedAddress.code.length > 0) {
            console.log("Skipping deployment of DutchDecayFeeModule as it already exists at", expectedAddress);
            return expectedAddress;
        }

        vm.broadcast();
        DutchDecayFeeModule module = new DutchDecayFeeModule{salt: bytes32(0)}();

        console.log("DutchDecayFeeModule deployed to:", address(module));
        return address(module);
    }
}
