// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {DeployLiquidityLauncherScript} from "./DeployLiquidityLauncher.s.sol";
import {DeployAdvancedLBPStrategyFactoryScript} from "./DeployAdvancedLBPStrategyFactory.s.sol";
import {DeployFullRangeLBPStrategyFactoryScript} from "./DeployFullRangeLBPStrategyFactory.s.sol";
import {DeployGovernedLBPStrategyFactoryScript} from "./DeployGovernedLBPStrategyFactory.s.sol";
import {console} from "forge-std/console.sol";

contract DeployAllScript is Script {
    DeployLiquidityLauncherScript public liquidityLauncherDeployer;
    DeployAdvancedLBPStrategyFactoryScript public advancedLBPStrategyFactoryDeployer;
    DeployFullRangeLBPStrategyFactoryScript public fullRangeLBPStrategyFactoryDeployer;
    DeployGovernedLBPStrategyFactoryScript public governedLBPStrategyFactoryDeployer;

    constructor() {
        liquidityLauncherDeployer = new DeployLiquidityLauncherScript();
        advancedLBPStrategyFactoryDeployer = new DeployAdvancedLBPStrategyFactoryScript();
        fullRangeLBPStrategyFactoryDeployer = new DeployFullRangeLBPStrategyFactoryScript();
        governedLBPStrategyFactoryDeployer = new DeployGovernedLBPStrategyFactoryScript();
    }

    function run() public {
        console.log("Deploying all contracts on chain", block.chainid);

        liquidityLauncherDeployer.run();
        advancedLBPStrategyFactoryDeployer.run();
        fullRangeLBPStrategyFactoryDeployer.run();
        governedLBPStrategyFactoryDeployer.run();
    }
}
