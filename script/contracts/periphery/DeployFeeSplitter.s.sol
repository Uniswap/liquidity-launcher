// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {FeeSplitter} from "../../../src/periphery/FeeSplitter.sol";
import {IFeeSplitter, FeeSplit} from "../../../src/interfaces/IFeeSplitter.sol";
import {console} from "forge-std/console.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {DeployParameters, Parameters} from "../Parameters.sol";

/// @title DeployFeeSplitterScript
/// @notice Deploys a FeeSplitter contract for the given chain
contract DeployFeeSplitterScript is Script, Parameters {
    function run() public returns (address feeSplitter) {
        DeployParameters memory params = getParameters(block.chainid);

        // Simple fee split sending all native to the tokenJar and all token to the burn address
        FeeSplit[] memory feeSplits = new FeeSplit[](2);
        feeSplits[0] =
            FeeSplit({recipient: getTokenJar(block.chainid), nativeBps: 10000, tokenBps: 0, useCallback: false});
        feeSplits[1] = FeeSplit({recipient: DEFAULT_BURN_ADDRESS, nativeBps: 0, tokenBps: 10000, useCallback: false});

        // Optionally use a salt for deployment
        bytes32 salt = bytes32(0);
        bytes memory bytecode =
            abi.encodePacked(type(FeeSplitter).creationCode, abi.encode(params.positionManager, feeSplits));
        bytes32 initCodeHash = keccak256(bytecode);
        address expectedAddress = Create2.computeAddress(salt, initCodeHash, DEFAULT_CREATE2_DEPLOYER);
        if (expectedAddress.code.length > 0) {
            console.log("Skipping deployment of FeeSplitter as it already exists at", expectedAddress);
            return expectedAddress;
        }

        vm.broadcast();
        feeSplitter = Create2.deploy(0, salt, bytecode);

        console.log("FeeSplitter deployed to:", feeSplitter);
        return feeSplitter;
    }
}
