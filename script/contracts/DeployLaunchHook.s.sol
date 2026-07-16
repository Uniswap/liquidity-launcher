// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {LaunchHook} from "../../src/periphery/hooks/LaunchHook.sol";
import {Parameters, DeployParameters} from "./Parameters.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

/// @title DeployLaunchHookScript
/// @notice Deploys the LaunchHook to a mined BEFORE_INITIALIZE | BEFORE_SWAP hook address
contract DeployLaunchHookScript is Script, Parameters {
    uint160 public constant LAUNCH_HOOK_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG;

    function run(address authorized) public returns (address) {
        DeployParameters memory params = getParameters(block.chainid);

        (address foundAddress, bytes32 foundSalt) = HookMiner.find(
            DEFAULT_CREATE2_DEPLOYER,
            LAUNCH_HOOK_FLAGS,
            type(LaunchHook).creationCode,
            abi.encode(params.poolManager, authorized)
        );
        console.logBytes32(foundSalt);

        if (foundAddress.code.length > 0) {
            console.log("Skipping deployment of LaunchHook as it already exists at", foundAddress);
            return foundAddress;
        }

        vm.broadcast();
        LaunchHook launchHook = new LaunchHook{salt: foundSalt}(params.poolManager, authorized);

        console.log("LaunchHook deployed to:", address(launchHook));
        require(address(launchHook) == foundAddress, "LaunchHook deployed to unexpected address");
        return address(launchHook);
    }
}
