// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {DeployLiquidityLauncherScript} from "./DeployLiquidityLauncher.s.sol";
import {DeployLBPStrategyScript} from "./DeployLBPStrategy.s.sol";
import {DeployTokenSplitterScript} from "./DeployTokenSplitter.s.sol";
import {IDistributorFactory} from "../../src/interfaces/IDistributorFactory.sol";
import {DeployInitializerHookScript} from "./periphery/DeployInitializerHook.s.sol";
import {DeployBeneficiaryVaultScript} from "./periphery/DeployBeneficiaryVault.s.sol";
import {DeployFeeSplitterScript} from "./periphery/DeployFeeSplitter.s.sol";
import {DeployCompoundingClaimRecipientScript} from "./periphery/DeployCompoundingClaimRecipient.s.sol";
import {DeployInstantLaunchStrategyScript} from "./DeployInstantLaunchStrategy.s.sol";
import {console} from "forge-std/console.sol";

contract DeployAllScript is Script {
    DeployLiquidityLauncherScript public liquidityLauncherDeployer;
    DeployLBPStrategyScript public lbpStrategyDeployer;
    DeployTokenSplitterScript public tokenSplitterDeployer;
    // Periphery deployers
    DeployInitializerHookScript public initializerHookDeployer;
    DeployBeneficiaryVaultScript public beneficiaryVaultDeployer;
    DeployFeeSplitterScript public feeSplitterDeployer;
    DeployCompoundingClaimRecipientScript public compoundingClaimRecipientDeployer;
    DeployInstantLaunchStrategyScript public instantLaunchStrategyDeployer;

    constructor() {
        liquidityLauncherDeployer = new DeployLiquidityLauncherScript();
        lbpStrategyDeployer = new DeployLBPStrategyScript();
        tokenSplitterDeployer = new DeployTokenSplitterScript();
        initializerHookDeployer = new DeployInitializerHookScript();
        beneficiaryVaultDeployer = new DeployBeneficiaryVaultScript();
        feeSplitterDeployer = new DeployFeeSplitterScript();
        compoundingClaimRecipientDeployer = new DeployCompoundingClaimRecipientScript();
        instantLaunchStrategyDeployer = new DeployInstantLaunchStrategyScript();
    }

    function run(IDistributorFactory initializerFactory) public {
        console.log("Deploying all contracts on chain", block.chainid);

        liquidityLauncherDeployer.run();
        address lbpStrategyAddress = lbpStrategyDeployer.run(initializerFactory);
        tokenSplitterDeployer.run();
        initializerHookDeployer.run(lbpStrategyAddress);

        // Deploy periphery contracts
        address beneficiaryVaultAddress = beneficiaryVaultDeployer.run();
        vm.setEnv("BENEFICIARY_VAULT", vm.toString(beneficiaryVaultAddress));
        address compoundingClaimRecipientAddress = compoundingClaimRecipientDeployer.run();
        vm.setEnv("COMPOUNDING_CLAIM_RECIPIENT", vm.toString(compoundingClaimRecipientAddress));
        // Deploy both variants of the fee splitter
        address feeSplitterWithCreatorFeeAddress = feeSplitterDeployer.deployWithCreatorFee();
        address feeSplitterWithoutCreatorFeeAddress = feeSplitterDeployer.deployWithoutCreatorFee();

        // Deploy strategy contracts, one with and one without creator fee
        address instantLaunchWithCreatorFeeAddress =
            instantLaunchStrategyDeployer.run(feeSplitterWithCreatorFeeAddress, beneficiaryVaultAddress);
        address instantLaunchWithoutCreatorFeeAddress =
            instantLaunchStrategyDeployer.run(feeSplitterWithoutCreatorFeeAddress, address(0));
    }
}
