// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {DirectLaunchStrategy} from "../../src/strategies/DirectLaunchStrategy.sol";
import {console} from "forge-std/console.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {DeployParameters, Parameters} from "./Parameters.sol";
import {IFeeSplitter} from "../../src/interfaces/IFeeSplitter.sol";
import {IBeneficiaryVault} from "../../src/interfaces/IBeneficiaryVault.sol";

contract DeployDirectLaunchStrategyScript is Script, Parameters {
    int24 public constant initialTick = 121_980;

    function run(address feeSplitter, address beneficiaryVault) public returns (address directLaunchStrategy) {
        DeployParameters memory params = getParameters(block.chainid);
        bytes memory bytecode = abi.encodePacked(
            type(DirectLaunchStrategy).creationCode,
            abi.encode(
                LIQUIDITY_LAUNCHER,
                params.positionManager,
                params.poolManager,
                IFeeSplitter(feeSplitter),
                IBeneficiaryVault(beneficiaryVault),
                initialTick
            )
        );
        bytes32 initCodeHash = keccak256(bytecode);
        console.logBytes32(initCodeHash);

        bytes32 salt = bytes32(0);
        address expectedAddress = Create2.computeAddress(salt, initCodeHash, DEFAULT_CREATE2_DEPLOYER);
        if (expectedAddress.code.length > 0) {
            console.log("Skipping deployment of DirectLaunchStrategy as it already exists at", expectedAddress);
            return expectedAddress;
        }

        vm.broadcast();
        directLaunchStrategy = Create2.deploy(0, salt, bytecode);
        console.log("DirectLaunchStrategy deployed to:", directLaunchStrategy);
        return directLaunchStrategy;
    }
}
