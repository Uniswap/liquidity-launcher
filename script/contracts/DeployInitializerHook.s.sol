// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {InitializerHook} from "../../src/periphery/hooks/InitializerHook.sol";
import {Parameters, DeployParameters} from "./Parameters.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {console} from "forge-std/console.sol";
import {Script} from "forge-std/Script.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

contract DeployInitializerHookScript is Script, Parameters {
    function run(address authorized) public {
        DeployParameters memory params = getParameters(block.chainid);
        bytes32 initCodeHash =
            keccak256(abi.encodePacked(type(InitializerHook).creationCode, abi.encode(params.poolManager, authorized)));

        // Otherwise, mine a salt that will produce a valid v4 hook address
        (address foundAddress, bytes32 foundSalt) = HookMiner.find(
            DEFAULT_CREATE2_DEPLOYER,
            DEFAULT_HOOK_FLAGS,
            type(InitializerHook).creationCode,
            abi.encode(params.poolManager, authorized)
        );
        console.logBytes32(foundSalt);

        if (foundAddress.code.length > 0) {
            console.log("Skipping deployment of InitializerHook as it already exists at", foundAddress);
            return;
        }

        vm.broadcast();
        InitializerHook initializerHook = new InitializerHook{salt: foundSalt}(params.poolManager, authorized);
        console.log("InitializerHook deployed to:", address(initializerHook));
    }
}
