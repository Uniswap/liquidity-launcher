// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {FeeSplit, FeeSplitter} from "../../src/periphery/FeeSplitter.sol";
import {console} from "forge-std/console.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {DeployParameters, Parameters} from "./Parameters.sol";

/// @title DeployFeeSplitterScript
/// @notice Deploys a FeeSplitter contract for the given chain
contract DeployFeeSplitterScript is Script, Parameters {
    address public constant RH_TOKEN_JAR = 0x2aC03e14Cfe755426DaAEe0a4994184Ce81482F8;
    address public constant BURN_ADDRESS = address(0xdead);
    function run() public {
        DeployParameters memory params = getParameters(block.chainid);

        FeeSplit[] memory nativeSplits = new FeeSplit[](1);
        nativeSplits[0] = FeeSplit({
            recipient: RH_TOKEN_JAR,
            bps: 10000
        });
        FeeSplit[] memory tokenSplits = new FeeSplit[](1);
        tokenSplits[0] = FeeSplit({
            recipient: BURN_ADDRESS, // burned
            bps: 10000
        });

        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(FeeSplitter).creationCode,
                abi.encode(
                    params.positionManager, RH_TOKEN_JAR, BURN_ADDRESS, nativeSplits, tokenSplits
                )
            )
        );
        console.logBytes32(initCodeHash);

        bytes32 salt = bytes32(0);
        address expectedAddress = Create2.computeAddress(salt, initCodeHash, DEFAULT_CREATE2_DEPLOYER);
        if (expectedAddress.code.length > 0) {
            console.log("Skipping deployment of FeeSplitter as it already exists at", expectedAddress);
            return;
        }

        vm.broadcast();
        FeeSplitter feeSplitter = new FeeSplitter{salt: salt}(params.positionManager, RH_TOKEN_JAR, BURN_ADDRESS, nativeSplits, tokenSplits);
        console.log("FeeSplitter deployed to:", address(feeSplitter));
    }
}
