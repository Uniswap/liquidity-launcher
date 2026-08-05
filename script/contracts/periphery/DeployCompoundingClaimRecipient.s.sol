// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {CompoundingClaimRecipient} from "../../../src/periphery/CompoundingClaimRecipient.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {DeployParameters, Parameters} from "../Parameters.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {console} from "forge-std/console.sol";

/// @title DeployCompoundingClaimRecipientScript
/// @notice Deploys a CompoundingClaimRecipient contract for the given chain
contract DeployCompoundingClaimRecipientScript is Script, Parameters {
    /// @notice Default required minimum liquidity amounts increase for compounding LP fees.
    /// @dev 0.2% of an `InstantLaunchStrategy` position's liquidity, which is ~$10 of assets to add at a $5k
    ///      launch FDV and ~$2.8k at $100M. `cost(dL)/value(L)` equals `dL/L` regardless of price, so this
    ///      stays at 0.2% of the position across the band; only the dollar figure moves with the position.
    uint128 public constant MIN_LIQUIDITY_INCREASE = 1e20;

    function run() public returns (address compoundingClaimRecipient) {
        DeployParameters memory params = getParameters(block.chainid);

        // Optionally use a salt for deployment
        bytes32 salt = vm.envOr("GLOBAL_SALT", bytes32(0));

        bytes memory bytecode = abi.encodePacked(
            type(CompoundingClaimRecipient).creationCode, abi.encode(params.positionManager, MIN_LIQUIDITY_INCREASE)
        );
        bytes32 initCodeHash = keccak256(bytecode);
        address expectedAddress = Create2.computeAddress(salt, initCodeHash, DEFAULT_CREATE2_DEPLOYER);
        if (expectedAddress.code.length > 0) {
            console.log("Skipping deployment of CompoundingClaimRecipient as it already exists at", expectedAddress);
            return expectedAddress;
        }

        vm.broadcast();
        compoundingClaimRecipient = Create2.deploy(0, salt, bytecode);
        console.log("CompoundingClaimRecipient deployed to:", compoundingClaimRecipient);
        return compoundingClaimRecipient;
    }
}
