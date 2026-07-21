// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IBondingCurveLaunchHook} from "../../src/interfaces/IBondingCurveLaunchHook.sol";
import {BondingCurveLaunchStrategy} from "../../src/strategies/BondingCurveLaunchStrategy.sol";
import {Parameters, DeployParameters} from "./Parameters.sol";

/// @title DeployBondingCurveLaunchStrategyScript
/// @notice Deploys BondingCurveLaunchStrategy with immutable launch configuration
contract DeployBondingCurveLaunchStrategyScript is Script, Parameters {
    /// @notice Deploys a bonding-curve strategy with fixed launch parameters.
    /// @param launcher The address authorized to launch tokens.
    /// @param launchHook The hook that owns and graduates curve positions.
    /// @param initialTick The initial curve tick.
    /// @param graduationTick The terminal curve tick.
    function run(address launcher, address launchHook, int24 initialTick, int24 graduationTick)
        public
        returns (address)
    {
        DeployParameters memory params = getParameters(block.chainid);

        vm.broadcast();
        BondingCurveLaunchStrategy strategy = new BondingCurveLaunchStrategy(
            launcher,
            params.positionManager,
            params.poolManager,
            IBondingCurveLaunchHook(launchHook),
            initialTick,
            graduationTick
        );

        console.log("BondingCurveLaunchStrategy deployed to:", address(strategy));
        return address(strategy);
    }
}
