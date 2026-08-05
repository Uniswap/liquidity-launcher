// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {InstantLaunchStrategy} from "../../src/strategies/InstantLaunchStrategy.sol";
import {console} from "forge-std/console.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {DeployParameters, Parameters} from "./Parameters.sol";
import {IFeeSplitter} from "../../src/interfaces/IFeeSplitter.sol";
import {IBeneficiaryVault} from "../../src/interfaces/IBeneficiaryVault.sol";

contract DeployInstantLaunchStrategyScript is Script, Parameters {
    int24 public constant initialTick = 198_050;

    function run(address feeSplitter, address beneficiaryVault) public returns (address instantLaunchStrategy) {
        DeployParameters memory params = getParameters(block.chainid);
        address liquidityLauncher = vm.envAddress("LIQUIDITY_LAUNCHER");
        if (liquidityLauncher == address(0)) revert("env: LIQUIDITY_LAUNCHER not set");

        bytes memory bytecode = abi.encodePacked(
            type(InstantLaunchStrategy).creationCode,
            abi.encode(
                liquidityLauncher,
                params.positionManager,
                params.poolManager,
                IFeeSplitter(feeSplitter),
                IBeneficiaryVault(beneficiaryVault),
                initialTick
            )
        );
        bytes32 initCodeHash = keccak256(bytecode);

        bytes32 salt = vm.envOr("GLOBAL_SALT", bytes32(0));

        address expectedAddress = Create2.computeAddress(salt, initCodeHash, DEFAULT_CREATE2_DEPLOYER);
        if (expectedAddress.code.length > 0) {
            console.log("Skipping deployment of InstantLaunchStrategy as it already exists at", expectedAddress);
            return expectedAddress;
        }

        vm.broadcast();
        instantLaunchStrategy = Create2.deploy(0, salt, bytecode);
        console.log("InstantLaunchStrategy deployed to:", instantLaunchStrategy);
        return instantLaunchStrategy;
    }
}
