// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {LiquidityLauncher} from "../../../src/LiquidityLauncher.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

contract DeployLiquidityLauncherMainnetScript is Script {
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    function run() public {
        vm.startBroadcast();

        bytes32 initCodeHash = keccak256(abi.encodePacked(type(LiquidityLauncher).creationCode, abi.encode(PERMIT2)));
        console.logBytes32(initCodeHash);

        // Deploys to 0x00000015D28A8fB49186EC679a590cE84fB05ea0
        bytes32 salt = 0x97568bc400723191e16fda6824488a2d3411d3a381e07e687c7580c4fe147668;
        LiquidityLauncher liquidityLauncher = new LiquidityLauncher{salt: salt}(IAllowanceTransfer(PERMIT2));

        console.log("LiquidityLauncher deployed to:", address(liquidityLauncher));
        vm.stopBroadcast();
    }
}
