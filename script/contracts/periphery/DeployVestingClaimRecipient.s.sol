// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {VestingClaimRecipient} from "../../../src/periphery/VestingClaimRecipient.sol";
import {IBeneficiaryVault} from "../../../src/interfaces/IBeneficiaryVault.sol";
import {IClaimableRecipient} from "../../../src/interfaces/IClaimableRecipient.sol";
import {DeployParameters, Parameters} from "../Parameters.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {console} from "forge-std/console.sol";

/// @title DeployVestingClaimRecipientScript
/// @notice Deploys a VestingClaimRecipient contract for the given chain
contract DeployVestingClaimRecipientScript is Script, Parameters {
    function run() public returns (address vestingClaimRecipient) {
        DeployParameters memory params = getParameters(block.chainid);

        address recipient = vm.envAddress("VESTING_RECIPIENT");
        if (recipient == address(0)) revert("env: VESTING_RECIPIENT not set");

        uint128 maxCurrency0PerBlock = uint128(vm.envUint("VESTING_MAX_CURRENCY0_PER_BLOCK"));
        uint128 maxCurrency1PerBlock = uint128(vm.envUint("VESTING_MAX_CURRENCY1_PER_BLOCK"));
        if (maxCurrency0PerBlock == 0 || maxCurrency1PerBlock == 0) {
            revert("env: VESTING_MAX_CURRENCY0_PER_BLOCK and VESTING_MAX_CURRENCY1_PER_BLOCK must both be non-zero");
        }

        address[] memory beneficiaryVaultAddresses = vm.envAddress("VESTING_BENEFICIARY_VAULTS", ",");
        if (beneficiaryVaultAddresses.length == 0) {
            revert("env: VESTING_BENEFICIARY_VAULTS must contain at least one address");
        }
        IBeneficiaryVault[] memory beneficiaryVaults = new IBeneficiaryVault[](beneficiaryVaultAddresses.length);
        for (uint256 i = 0; i < beneficiaryVaultAddresses.length; i++) {
            if (beneficiaryVaultAddresses[i] == address(0)) {
                revert("env: VESTING_BENEFICIARY_VAULTS cannot contain the zero address");
            }
            beneficiaryVaults[i] = IBeneficiaryVault(beneficiaryVaultAddresses[i]);
        }

        // Optionally use a salt for deployment
        bytes32 salt = vm.envOr("GLOBAL_SALT", bytes32(0));

        bytes memory bytecode = abi.encodePacked(
            type(VestingClaimRecipient).creationCode,
            abi.encode(
                params.positionManager,
                maxCurrency0PerBlock,
                maxCurrency1PerBlock,
                IClaimableRecipient(recipient),
                beneficiaryVaults
            )
        );
        bytes32 initCodeHash = keccak256(bytecode);
        address expectedAddress = Create2.computeAddress(salt, initCodeHash, DEFAULT_CREATE2_DEPLOYER);
        if (expectedAddress.code.length > 0) {
            console.log("Skipping deployment of VestingClaimRecipient as it already exists at", expectedAddress);
            return expectedAddress;
        }

        vm.broadcast();
        vestingClaimRecipient = Create2.deploy(0, salt, bytecode);
        console.log("VestingClaimRecipient deployed to:", vestingClaimRecipient);
        return vestingClaimRecipient;
    }
}
