// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {DutchDecayFeeModule} from "../../src/periphery/modules/DutchDecayFeeModule.sol";
import {Parameters} from "./Parameters.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

/// @title DeployDutchDecayFeeModuleScript
/// @notice Deploys the DutchDecayFeeModule singleton
contract DeployDutchDecayFeeModuleScript is Script, Parameters {
    // Bonding-curve launch fee: 99% at the swap-start block, decaying linearly to 0 over 5 blocks,
    // taxing both directions.
    uint24 internal constant START_FEE = 990_000;
    uint24 internal constant END_FEE = 0;
    uint48 internal constant DECAY_BLOCKS = 5;
    bool internal constant TAX_BOTH_DIRECTIONS = true;

    function run() public returns (address) {
        bytes memory args = abi.encode(START_FEE, END_FEE, DECAY_BLOCKS, TAX_BOTH_DIRECTIONS);
        bytes32 initCodeHash = keccak256(abi.encodePacked(type(DutchDecayFeeModule).creationCode, args));
        address expectedAddress = Create2.computeAddress(bytes32(0), initCodeHash, DEFAULT_CREATE2_DEPLOYER);
        if (expectedAddress.code.length > 0) {
            console.log("Skipping deployment of DutchDecayFeeModule as it already exists at", expectedAddress);
            return expectedAddress;
        }

        vm.broadcast();
        DutchDecayFeeModule module =
            new DutchDecayFeeModule{salt: bytes32(0)}(START_FEE, END_FEE, DECAY_BLOCKS, TAX_BOTH_DIRECTIONS);

        console.log("DutchDecayFeeModule deployed to:", address(module));
        return address(module);
    }
}
