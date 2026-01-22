// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {AdvancedLBPStrategyFactory} from "@lbp/factories/AdvancedLBPStrategyFactory.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {DeployParameters, Parameters} from "./Parameters.sol";

/// @title DeployAdvancedLBPStrategyFactoryScript
/// @notice Deploys the AdvancedLBPStrategyFactory contract given a position manager and pool manager
contract DeployAdvancedLBPStrategyFactoryScript is Script, Parameters {
    function run() public {
        DeployParameters memory params = getParameters(block.chainid);
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(AdvancedLBPStrategyFactory).creationCode, abi.encode(params.positionManager, params.poolManager)
            )
        );
        address factoryAddress = Create2.computeAddress(params.salt, initCodeHash, DEFAULT_CREATE2_DEPLOYER);

        if (address(factoryAddress).code.length > 0) {
            console.log("Skipping deployment of AdvancedLBPStrategyFactory as it already exists at", factoryAddress);
            return;
        }

        vm.broadcast();
        AdvancedLBPStrategyFactory factory =
            new AdvancedLBPStrategyFactory{salt: params.salt}(params.positionManager, params.poolManager);

        console.log("AdvancedLBPStrategyFactory deployed to:", address(factory));
    }
}
