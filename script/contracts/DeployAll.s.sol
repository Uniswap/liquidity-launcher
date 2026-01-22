// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {DeployLiquidityLauncherScript} from "./DeployLiquidityLauncher.s.sol";
import {DeployAdvancedLBPStrategyFactoryScript} from "./DeployAdvancedLBPStrategyFactory.sol";
import {DeployFullRangeLBPStrategyFactoryScript} from "./DeployFullRangeLBPStrategyFactory.s.sol";
import {console} from "forge-std/console.sol";

contract DeployAllScript is Script {
    DeployLiquidityLauncherScript public liquidityLauncherDeployer;
    DeployAdvancedLBPStrategyFactoryScript public advancedLBPStrategyFactoryDeployer;
    DeployFullRangeLBPStrategyFactoryScript public fullRangeLBPStrategyFactoryDeployer;

    constructor() {
        liquidityLauncherDeployer = new DeployLiquidityLauncherScript();
        advancedLBPStrategyFactoryDeployer = new DeployAdvancedLBPStrategyFactoryScript();
        fullRangeLBPStrategyFactoryDeployer = new DeployFullRangeLBPStrategyFactoryScript();
    }

    function run() public {
        console.log("Deploying all contracts on chain", block.chainid);

        liquidityLauncherDeployer.run();
        advancedLBPStrategyFactoryDeployer.run();
        fullRangeLBPStrategyFactoryDeployer.run();
    }
}
