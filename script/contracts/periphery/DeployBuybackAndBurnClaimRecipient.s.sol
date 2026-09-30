// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BuybackAndBurnClaimRecipient} from "../../../src/periphery/BuybackAndBurnClaimRecipient.sol";
import {DeployParameters, Parameters} from "../Parameters.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {console} from "forge-std/console.sol";

/// @title DeployBuybackAndBurnClaimRecipientScript
/// @notice Deploys a BuybackAndBurnClaimRecipient contract for the given chain
contract DeployBuybackAndBurnClaimRecipientScript is Script, Parameters {
    /// @notice Default minimum amount of the burn currency to burn per call.
    /// @dev This is set to 500,000 tokens assuming 18 decimals which is approx 0.05% of total supply.
    uint256 public constant DEFAULT_MIN_BURN_AMOUNT = 500_000e18;

    function run() public returns (address buybackAndBurnClaimRecipient) {
        DeployParameters memory params = getParameters(block.chainid);

        // Old names must not linger: they are part of CREATE2 init code and would silently drift.
        require(!vm.envExists("MIN_CURRENCY1_BURN_AMOUNT"), "env: MIN_CURRENCY1_BURN_AMOUNT renamed to MIN_BURN_AMOUNT");
        require(
            !vm.envExists("BURN_CURRENCY0"),
            "env: BURN_CURRENCY0 removed; set QUOTE_CURRENCY (non-quote side is burned)"
        );

        // Quote currency whose counterpart is burned; defaults to native (burns the ERC20 token side).
        Currency quoteCurrency = Currency.wrap(vm.envOr("QUOTE_CURRENCY", address(0)));
        uint256 minBurnAmount = vm.envOr("MIN_BURN_AMOUNT", DEFAULT_MIN_BURN_AMOUNT);

        // Optionally use a salt for deployment
        bytes32 salt = vm.envOr("GLOBAL_SALT", bytes32(0));

        bytes memory bytecode = abi.encodePacked(
            type(BuybackAndBurnClaimRecipient).creationCode,
            abi.encode(params.positionManager, quoteCurrency, minBurnAmount)
        );
        bytes32 initCodeHash = keccak256(bytecode);
        address expectedAddress = Create2.computeAddress(salt, initCodeHash, DEFAULT_CREATE2_DEPLOYER);
        if (expectedAddress.code.length > 0) {
            console.log("Skipping deployment of BuybackAndBurnClaimRecipient as it already exists at", expectedAddress);
            return expectedAddress;
        }

        vm.broadcast();
        buybackAndBurnClaimRecipient = Create2.deploy(0, salt, bytecode);
        console.log("BuybackAndBurnClaimRecipient deployed to:", buybackAndBurnClaimRecipient);
        return buybackAndBurnClaimRecipient;
    }
}
