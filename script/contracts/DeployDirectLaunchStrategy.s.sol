// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {DirectLaunchStrategy} from "../../src/strategies/DirectLaunchStrategy.sol";
import {Parameters, DeployParameters} from "./Parameters.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

/// @title DeployDirectLaunchStrategyScript
/// @notice Deploys the DirectLaunchStrategy singleton
contract DeployDirectLaunchStrategyScript is Script, Parameters {
    function run() public returns (address) {
        DeployParameters memory params = getParameters(block.chainid);

        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(DirectLaunchStrategy).creationCode, abi.encode(params.positionManager, params.poolManager)
            )
        );
        address expectedAddress = Create2.computeAddress(bytes32(0), initCodeHash, DEFAULT_CREATE2_DEPLOYER);
        if (expectedAddress.code.length > 0) {
            console.log("Skipping deployment of DirectLaunchStrategy as it already exists at", expectedAddress);
            return expectedAddress;
        }

        vm.broadcast();
        DirectLaunchStrategy directLaunchStrategy =
            new DirectLaunchStrategy{salt: bytes32(0)}(params.positionManager, params.poolManager);

        console.log("DirectLaunchStrategy deployed to:", address(directLaunchStrategy));
        require(address(directLaunchStrategy).code.length > 0, "DirectLaunchStrategy deployment failed");
        return address(directLaunchStrategy);
    }
}
