// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {DeployLiquidityLauncherScript} from "./DeployLiquidityLauncher.s.sol";
import {DeployLBPStrategyScript} from "./DeployLBPStrategy.s.sol";
import {IDistributorFactory} from "src/interfaces/IDistributorFactory.sol";
import {console} from "forge-std/console.sol";

contract DeployAllScript is Script {
    DeployLiquidityLauncherScript public liquidityLauncherDeployer;
    DeployLBPStrategyScript public lbpStrategyDeployer;

    constructor() {
        liquidityLauncherDeployer = new DeployLiquidityLauncherScript();
        lbpStrategyDeployer = new DeployLBPStrategyScript();
    }

    function run(IDistributorFactory initializerFactory, uint256 recoveryDelayBlocks) public {
        console.log("Deploying all contracts on chain", block.chainid);

        liquidityLauncherDeployer.run();
        lbpStrategyDeployer.run(initializerFactory, recoveryDelayBlocks);
    }
}
