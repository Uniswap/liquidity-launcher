// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {BondingCurveLaunchHook} from "../../src/periphery/hooks/BondingCurveLaunchHook.sol";
import {Parameters, DeployParameters} from "./Parameters.sol";

/// @title DeployBondingCurveLaunchHookScript
/// @notice Deploys BondingCurveLaunchHook to a valid v4 hook address
contract DeployBondingCurveLaunchHookScript is Script, Parameters {
    uint160 public constant BONDING_CURVE_HOOK_FLAGS =
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG;

    /// @notice Predicts the mined hook address for an authorized bonding-curve strategy.
    /// @param authorized The strategy authorized to initialize curve pools.
    function predict(address authorized) public view returns (address hookAddress, bytes32 salt) {
        DeployParameters memory params = getParameters(block.chainid);
        return HookMiner.find(
            DEFAULT_CREATE2_DEPLOYER,
            BONDING_CURVE_HOOK_FLAGS,
            type(BondingCurveLaunchHook).creationCode,
            abi.encode(params.poolManager, params.positionManager, authorized)
        );
    }

    /// @notice Deploys the mined bonding-curve hook.
    /// @param authorized The strategy authorized to initialize curve pools.
    function run(address authorized) public returns (address) {
        DeployParameters memory params = getParameters(block.chainid);
        (address hookAddress, bytes32 salt) = predict(authorized);
        console.logBytes32(salt);

        if (hookAddress.code.length > 0) {
            console.log("Skipping deployment of BondingCurveLaunchHook as it already exists at", hookAddress);
            return hookAddress;
        }

        vm.broadcast();
        BondingCurveLaunchHook hook =
            new BondingCurveLaunchHook{salt: salt}(params.poolManager, params.positionManager, authorized);

        console.log("BondingCurveLaunchHook deployed to:", address(hook));
        require(address(hook) == hookAddress, "BondingCurveLaunchHook deployed to unexpected address");
        return hookAddress;
    }
}
