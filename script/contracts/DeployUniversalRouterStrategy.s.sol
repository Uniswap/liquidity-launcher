// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {UniversalRouterStrategy} from "../../src/strategies/UniversalRouterStrategy.sol";
import {console} from "forge-std/console.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {DeployParameters, Parameters} from "./Parameters.sol";

contract DeployUniversalRouterStrategyScript is Script, Parameters {
    function run() public returns (address universalRouterStrategy) {
        DeployParameters memory params = getParameters(block.chainid);
        bytes memory bytecode = abi.encodePacked(
            type(UniversalRouterStrategy).creationCode,
            abi.encode(LIQUIDITY_LAUNCHER)
        );
        bytes32 initCodeHash = keccak256(bytecode);

        bytes32 salt = bytes32(0);
        address expectedAddress = Create2.computeAddress(salt, initCodeHash, DEFAULT_CREATE2_DEPLOYER);
        if (expectedAddress.code.length > 0) {
            console.log("Skipping deployment of UniversalRouterStrategy as it already exists at", expectedAddress);
            return expectedAddress;
        }

        vm.broadcast();
        universalRouterStrategy = Create2.deploy(0, salt, bytecode);
        console.log("UniversalRouterStrategy deployed to:", universalRouterStrategy);
        return universalRouterStrategy;
    }
}
