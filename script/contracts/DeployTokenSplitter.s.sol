// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {TokenSplitter} from "../../src/strategies/TokenSplitter.sol";
import {console} from "forge-std/console.sol";

contract DeployTokenSplitterScript is Script {
    function run() public {
        vm.broadcast();
        TokenSplitter tokenSplitter = new TokenSplitter{salt: bytes32(0)}();
        console.log("TokenSplitter deployed to:", address(tokenSplitter));
    }
}
