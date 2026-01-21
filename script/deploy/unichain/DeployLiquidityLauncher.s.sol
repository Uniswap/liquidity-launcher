// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {LiquidityLauncher} from "../../../src/LiquidityLauncher.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

/**
 * @title DeployLiquidityLauncherUnichainScript
 * @notice Script for deploying LiquidityLauncher with a deterministic address via CREATE2.
 * This ensures the same contract address across different EVM chains if the salt remains identical.
 */
contract DeployLiquidityLauncherUnichainScript is Script {
    // Permit2 address is standard across most EVM chains
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    function run() public {
        // Fetching deployment private key from environment for security
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        /**
         * CREATE2 Salt: Used to pre-calculate and secure the 0x00000008... address.
         * Deterministic deployment is critical for front-end integration and cross-chain consistency.
         */
        bytes32 salt = 0x9a269ec151cdb4159e40d33648400e3ac814791b0051656925f1f8b53831aab7;

        // Deployment with Salt (CREATE2)
        LiquidityLauncher liquidityLauncher = new LiquidityLauncher{salt: salt}(
            IAllowanceTransfer(PERMIT2)
        );

        [Image of Ethereum CREATE2 opcode and deterministic address generation]

        console.log("--------------------------------------------------");
        console.log("Deployment Network: Unichain");
        console.log("LiquidityLauncher: ", address(liquidityLauncher));
        console.log("Permit2 Interface: ", PERMIT2);
        console.log("--------------------------------------------------");

        vm.stopBroadcast();
    }
}
