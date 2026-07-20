// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {DeployBondingCurveLaunchHookScript} from "./DeployBondingCurveLaunchHook.s.sol";
import {DeployBondingCurveLaunchStrategyScript} from "./DeployBondingCurveLaunchStrategy.s.sol";

/// @title DeployBondingCurveLaunchScript
/// @notice Deploys the bonding-curve strategy and hook
contract DeployBondingCurveLaunchScript is Script {
    DeployBondingCurveLaunchHookScript public immutable bondingCurveHookDeployer;
    DeployBondingCurveLaunchStrategyScript public immutable bondingCurveStrategyDeployer;

    constructor() {
        bondingCurveHookDeployer = new DeployBondingCurveLaunchHookScript();
        bondingCurveStrategyDeployer = new DeployBondingCurveLaunchStrategyScript();
    }

    /// @notice Deploys the bonding-curve strategy and mined hook.
    /// @param launcher The address authorized to launch tokens.
    /// @param initialTick The initial curve tick.
    /// @param graduationTick The terminal curve tick.
    function run(address launcher, int24 initialTick, int24 graduationTick)
        public
        returns (address strategy, address hook)
    {
        address deployer = tx.origin;
        strategy = vm.computeCreateAddress(deployer, vm.getNonce(deployer));
        (hook,) = bondingCurveHookDeployer.predict(strategy);

        address deployedStrategy = bondingCurveStrategyDeployer.run(launcher, hook, initialTick, graduationTick);
        require(deployedStrategy == strategy, "BondingCurveLaunchStrategy deployed to unexpected address");

        address deployedHook = bondingCurveHookDeployer.run(strategy);
        require(deployedHook == hook, "BondingCurveLaunchHook deployed to unexpected address");

        console.log("Bonding curve launch deployed with strategy:", strategy);
        console.log("Bonding curve launch deployed with hook:", hook);
    }
}
