// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {FeeSplitter} from "../../../src/periphery/FeeSplitter.sol";
import {IFeeSplitter, FeeSplit} from "../../../src/interfaces/IFeeSplitter.sol";
import {IBeneficiaryVault} from "../../../src/interfaces/IBeneficiaryVault.sol";
import {BuybackAndBurnClaimRecipient} from "../../../src/periphery/BuybackAndBurnClaimRecipient.sol";
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
        // Vault fallback routing is by its own quoteCurrency; a mismatch sends the creator's
        // unregistered quote share to tokenFallback (0xdead) instead of quoteFallback (TokenJar).
        Currency quoteCurrency = Currency.wrap(vm.envOr("QUOTE_CURRENCY", address(0)));
        require(
            IBeneficiaryVault(beneficiaryVault).quoteCurrency() == quoteCurrency,
            "env: BENEFICIARY_VAULT quoteCurrency must match QUOTE_CURRENCY"
        );

        address recipient;
        address compoundingClaimRecipient = vm.envOr("COMPOUNDING_CLAIM_RECIPIENT", address(0));
        address buybackAndBurnClaimRecipient = vm.envOr("BUYBACK_AND_BURN_CLAIM_RECIPIENT", address(0));
        if (compoundingClaimRecipient != address(0)) {
            require(
                buybackAndBurnClaimRecipient == address(0),
                "env: BUYBACK_AND_BURN_CLAIM_RECIPIENT cannot be set when COMPOUNDING_CLAIM_RECIPIENT is set"
            );
            recipient = compoundingClaimRecipient;
        } else {
            require(buybackAndBurnClaimRecipient != address(0), "env: BUYBACK_AND_BURN_CLAIM_RECIPIENT not set");
            require(
                BuybackAndBurnClaimRecipient(payable(buybackAndBurnClaimRecipient)).quoteCurrency() == quoteCurrency,
                "env: BUYBACK_AND_BURN_CLAIM_RECIPIENT quoteCurrency must match QUOTE_CURRENCY"
            );
            recipient = buybackAndBurnClaimRecipient;
        }

        FeeSplit[] memory feeSplits = new FeeSplit[](2);
        feeSplits[0] = FeeSplit({recipient: beneficiaryVault, quoteBps: 4_000, tokenBps: 0, useCallback: true}); // 40% of quote fees go to beneficiary vault
        feeSplits[1] = FeeSplit({recipient: recipient, quoteBps: 6_000, tokenBps: 10_000, useCallback: true}); // Remainder of quote and all token fees go to compounder

        return _deploy(params, feeSplits);
    }

    function deployWithoutCreatorFee() public returns (address feeSplitter) {
        DeployParameters memory params = getParameters(block.chainid);

        // Simple fee split setup.
        address compoundingClaimRecipient = vm.envOr("COMPOUNDING_CLAIM_RECIPIENT", address(0));
        address buybackAndBurnClaimRecipient = vm.envOr("BUYBACK_AND_BURN_CLAIM_RECIPIENT", address(0));
        address recipient;
        if (compoundingClaimRecipient != address(0)) {
            require(
                buybackAndBurnClaimRecipient == address(0),
                "env: BUYBACK_AND_BURN_CLAIM_RECIPIENT cannot be set when COMPOUNDING_CLAIM_RECIPIENT is set"
            );
            recipient = compoundingClaimRecipient;
        } else {
            require(buybackAndBurnClaimRecipient != address(0), "env: BUYBACK_AND_BURN_CLAIM_RECIPIENT not set");
            // Same quote invariant as deployWithCreatorFee / BeneficiaryVault: mismatched immutable
            // Buyback quote locks the wrong burn side into the FeeSplitter split.
            Currency quoteCurrency = Currency.wrap(vm.envOr("QUOTE_CURRENCY", address(0)));
            require(
                BuybackAndBurnClaimRecipient(payable(buybackAndBurnClaimRecipient)).quoteCurrency() == quoteCurrency,
                "env: BUYBACK_AND_BURN_CLAIM_RECIPIENT quoteCurrency must match QUOTE_CURRENCY"
            );
            recipient = buybackAndBurnClaimRecipient;
        }

        FeeSplit[] memory feeSplits = new FeeSplit[](1);
        feeSplits[0] = FeeSplit({recipient: recipient, quoteBps: 10_000, tokenBps: 10_000, useCallback: true}); // 100% of quote and token fees go to compounder

        return _deploy(params, feeSplits);
    }
}
