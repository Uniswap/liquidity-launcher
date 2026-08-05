// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {TokenSplitter} from "../../src/strategies/TokenSplitter.sol";
import {console} from "forge-std/console.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {Parameters} from "./Parameters.sol";

contract DeployTokenSplitterScript is Script, Parameters {
    function run() public {
        bytes32 initCodeHash = keccak256(abi.encodePacked(type(TokenSplitter).creationCode));

        bytes32 salt = vm.envOr("GLOBAL_SALT", bytes32(0));

        address expectedAddress = Create2.computeAddress(salt, initCodeHash, DEFAULT_CREATE2_DEPLOYER);
        if (expectedAddress.code.length > 0) {
            console.log("Skipping deployment of TokenSplitter as it already exists at", expectedAddress);
            return;
        }

        vm.broadcast();
        TokenSplitter tokenSplitter = new TokenSplitter{salt: salt}();
        console.log("TokenSplitter deployed to:", address(tokenSplitter));
    }
}
