// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {FeeSplitter} from "../../../src/periphery/FeeSplitter.sol";
import {IFeeSplitter, FeeSplit} from "../../../src/interfaces/IFeeSplitter.sol";
import {console} from "forge-std/console.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {DeployParameters, Parameters} from "../Parameters.sol";

/// @title DeployFeeSplitterScript
/// @notice Deploys a FeeSplitter contract for the given chain
contract DeployFeeSplitterScript is Script, Parameters {
    /// @notice Deploys a FeeSplitter contract with the given parameters
    /// @param params The parameters for the FeeSplitter
    /// @return feeSplitter The address of the deployed FeeSplitter
    function _deploy(DeployParameters memory params, FeeSplit[] memory feeSplits)
        internal
        returns (address feeSplitter)
    {
        // Optionally use a salt for deployment
        bytes32 salt = vm.envOr("GLOBAL_SALT", bytes32(0));
        // The quote currency every serviced position must pair; defaults to the native currency.
        Currency quoteCurrency = Currency.wrap(vm.envOr("QUOTE_CURRENCY", address(0)));

        bytes memory bytecode = abi.encodePacked(
            type(FeeSplitter).creationCode, abi.encode(params.positionManager, quoteCurrency, feeSplits)
        );
        bytes32 initCodeHash = keccak256(bytecode);
        address expectedAddress = Create2.computeAddress(salt, initCodeHash, DEFAULT_CREATE2_DEPLOYER);
        if (expectedAddress.code.length > 0) {
            console.log("Skipping deployment of FeeSplitter as it already exists at", expectedAddress);
            return expectedAddress;
        }

        vm.broadcast();
        feeSplitter = Create2.deploy(0, salt, bytecode);

        console.log("FeeSplitter deployed to:", feeSplitter);
    }

    function deployWithCreatorFee() public returns (address feeSplitter) {
        DeployParameters memory params = getParameters(block.chainid);

        // Simple fee split setup.
        address beneficiaryVault = vm.envAddress("BENEFICIARY_VAULT");
        address compoundingClaimRecipient = vm.envAddress("COMPOUNDING_CLAIM_RECIPIENT");
        if (beneficiaryVault == address(0)) revert("env: BENEFICIARY_VAULT not set");
        if (compoundingClaimRecipient == address(0)) revert("env: COMPOUNDING_CLAIM_RECIPIENT not set");

        FeeSplit[] memory feeSplits = new FeeSplit[](2);
        feeSplits[0] = FeeSplit({recipient: beneficiaryVault, quoteBps: 4_000, tokenBps: 0, useCallback: true}); // 40% of quote fees go to beneficiary vault
        feeSplits[1] =
            FeeSplit({recipient: compoundingClaimRecipient, quoteBps: 6_000, tokenBps: 10_000, useCallback: true}); // Remainder of quote and all token fees go to compounder

        return _deploy(params, feeSplits);
    }

    function deployWithoutCreatorFee() public returns (address feeSplitter) {
        DeployParameters memory params = getParameters(block.chainid);

        // Simple fee split setup.
        address compoundingClaimRecipient = vm.envAddress("COMPOUNDING_CLAIM_RECIPIENT");
        if (compoundingClaimRecipient == address(0)) revert("env: COMPOUNDING_CLAIM_RECIPIENT not set");

        FeeSplit[] memory feeSplits = new FeeSplit[](1);
        feeSplits[0] =
            FeeSplit({recipient: compoundingClaimRecipient, quoteBps: 10_000, tokenBps: 10_000, useCallback: true}); // 100% of quote and token fees go to compounder

        return _deploy(params, feeSplits);
    }
}
