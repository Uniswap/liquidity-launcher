// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {DeployLiquidityLauncherScript} from "./DeployLiquidityLauncher.s.sol";
import {DeployLBPStrategyScript} from "./DeployLBPStrategy.s.sol";
import {DeployTokenSplitterScript} from "./DeployTokenSplitter.s.sol";
import {IDistributorFactory} from "src/interfaces/IDistributorFactory.sol";
import {console} from "forge-std/console.sol";

contract DeployAllScript is Script {
    DeployLiquidityLauncherScript public liquidityLauncherDeployer;
    DeployLBPStrategyScript public lbpStrategyDeployer;
    DeployTokenSplitterScript public tokenSplitterDeployer;

    constructor() {
        liquidityLauncherDeployer = new DeployLiquidityLauncherScript();
        lbpStrategyDeployer = new DeployLBPStrategyScript();
        tokenSplitterDeployer = new DeployTokenSplitterScript();
    }

    function run(IDistributorFactory initializerFactory) public {
        console.log("Deploying all contracts on chain", block.chainid);

        liquidityLauncherDeployer.run();
        lbpStrategyDeployer.run(initializerFactory);
        tokenSplitterDeployer.run();
    }
}
