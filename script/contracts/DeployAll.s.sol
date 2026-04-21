// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {DeployLiquidityLauncherScript} from "./DeployLiquidityLauncher.s.sol";
import {console} from "forge-std/console.sol";

contract DeployAllScript is Script {
    DeployLiquidityLauncherScript public liquidityLauncherDeployer;

    constructor() {
        liquidityLauncherDeployer = new DeployLiquidityLauncherScript();
    }

    function run() public {
        console.log("Deploying all contracts on chain", block.chainid);

        liquidityLauncherDeployer.run();
    }
}
