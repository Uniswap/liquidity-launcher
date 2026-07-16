// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {DeployLiquidityLauncherScript} from "./DeployLiquidityLauncher.s.sol";
import {DeployLBPStrategyScript} from "./DeployLBPStrategy.s.sol";
import {DeployTokenSplitterScript} from "./DeployTokenSplitter.s.sol";
import {IDistributorFactory} from "../../src/interfaces/IDistributorFactory.sol";
import {DeployInitializerHookScript} from "./DeployInitializerHook.s.sol";
import {DeployDirectLaunchStrategyScript} from "./DeployDirectLaunchStrategy.s.sol";
import {DeployLaunchHookScript} from "./DeployLaunchHook.s.sol";
import {DeployDutchDecayFeeModuleScript} from "./DeployDutchDecayFeeModule.s.sol";
import {console} from "forge-std/console.sol";

contract DeployAllScript is Script {
    DeployLiquidityLauncherScript public liquidityLauncherDeployer;
    DeployLBPStrategyScript public lbpStrategyDeployer;
    DeployTokenSplitterScript public tokenSplitterDeployer;
    DeployInitializerHookScript public initializerHookDeployer;
    DeployDirectLaunchStrategyScript public directLaunchStrategyDeployer;
    DeployLaunchHookScript public launchHookDeployer;
    DeployDutchDecayFeeModuleScript public dutchDecayFeeModuleDeployer;

    constructor() {
        liquidityLauncherDeployer = new DeployLiquidityLauncherScript();
        lbpStrategyDeployer = new DeployLBPStrategyScript();
        tokenSplitterDeployer = new DeployTokenSplitterScript();
        initializerHookDeployer = new DeployInitializerHookScript();
        directLaunchStrategyDeployer = new DeployDirectLaunchStrategyScript();
        launchHookDeployer = new DeployLaunchHookScript();
        dutchDecayFeeModuleDeployer = new DeployDutchDecayFeeModuleScript();
    }

    function run(IDistributorFactory initializerFactory) public {
        console.log("Deploying all contracts on chain", block.chainid);

        liquidityLauncherDeployer.run();
        address lbpStrategyAddress = lbpStrategyDeployer.run(initializerFactory);
        tokenSplitterDeployer.run();
        initializerHookDeployer.run(lbpStrategyAddress);
        address directLaunchStrategyAddress = directLaunchStrategyDeployer.run();
        launchHookDeployer.run(directLaunchStrategyAddress);
        dutchDecayFeeModuleDeployer.run();
    }
}
