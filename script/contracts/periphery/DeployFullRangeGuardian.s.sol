// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {FullRangeGuardian} from "../../../src/periphery/FullRangeGuardian.sol";
import {DeployParameters, Parameters} from "../Parameters.sol";

/// @title DeployFullRangeGuardianScript
/// @notice Deploys a FullRangeGuardian for the given chain
/// @dev Deployed via broadcast, not Create2, so `deployer` is the broadcaster.
contract DeployFullRangeGuardianScript is Script, Parameters {
    function run() public returns (address guardian) {
        DeployParameters memory params = getParameters(block.chainid);

        address owner = vm.envAddress("GUARDIAN_OWNER");
        if (owner == address(0)) revert("env: GUARDIAN_OWNER not set");

        address[] memory feeSplitters = vm.envAddress("FEE_SPLITTERS", ",");
        if (feeSplitters.length == 0) revert("env: FEE_SPLITTERS not set");

        address[] memory compounders = _loadCompounders(feeSplitters.length);
        require(feeSplitters.length == compounders.length, "FEE_SPLITTERS and COMPOUNDERS length mismatch");

        vm.startBroadcast();
        guardian = address(new FullRangeGuardian(params.positionManager, owner, feeSplitters, compounders));
        vm.stopBroadcast();

        console.log("FullRangeGuardian deployed to:", guardian);
    }

    /// @dev Accept either a comma-separated `COMPOUNDERS` list or a single `COMPOUNDING_CLAIM_RECIPIENT`
    ///      broadcast to every fee splitter.
    function _loadCompounders(uint256 feeSplitterCount) private view returns (address[] memory compounders) {
        compounders = vm.envAddress("COMPOUNDERS", ",");
        if (compounders.length != 0) return compounders;

        address compounder = vm.envAddress("COMPOUNDING_CLAIM_RECIPIENT");
        if (compounder == address(0)) revert("env: COMPOUNDERS or COMPOUNDING_CLAIM_RECIPIENT not set");

        compounders = new address[](feeSplitterCount);
        for (uint256 i = 0; i < feeSplitterCount; i++) {
            compounders[i] = compounder;
        }
    }
}
