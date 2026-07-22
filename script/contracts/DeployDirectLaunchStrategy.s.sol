// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {DirectLaunchStrategy} from "../../src/strategies/DirectLaunchStrategy.sol";
import {console} from "forge-std/console.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import { DeployParameters, Parameters} from "./Parameters.sol";
import {IFeeSplitter} from "../../src/interfaces/IFeeSplitter.sol";

contract DeployDirectLaunchStrategyScript is Script, Parameters {
    int24 public constant initialTick = 121_980;

    function run(address feeSplitter) public {
        DeployParameters memory params = getParameters(block.chainid);
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(DirectLaunchStrategy).creationCode,
                abi.encode(LIQUIDITY_LAUNCHER, params.positionManager, params.poolManager, feeSplitter, initialTick)
            )
        );
        console.logBytes32(initCodeHash);

        bytes32 salt = bytes32(0);
        address expectedAddress = Create2.computeAddress(salt, initCodeHash, DEFAULT_CREATE2_DEPLOYER);
        if (expectedAddress.code.length > 0) {
            console.log("Skipping deployment of DirectLaunchStrategy as it already exists at", expectedAddress);
            return;
        }

        vm.broadcast();
        DirectLaunchStrategy directLaunchStrategy = new DirectLaunchStrategy{salt: salt}(
            LIQUIDITY_LAUNCHER, params.positionManager, params.poolManager, IFeeSplitter(feeSplitter), initialTick
        );
        console.log("DirectLaunchStrategy deployed to:", address(directLaunchStrategy));
    }
}
