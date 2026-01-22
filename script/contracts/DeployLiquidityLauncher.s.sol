// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {LiquidityLauncher} from "src/LiquidityLauncher.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {Parameters} from "./Parameters.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

/// @title DeployLiquidityLauncherScript
/// @notice Since LiquidityLauncher takes no chain dependent parameters it can be deployed to the same address on all chains
contract DeployLiquidityLauncherScript is Script, Parameters {
    function run() public {
        bytes32 initCodeHash = keccak256(abi.encodePacked(type(LiquidityLauncher).creationCode, abi.encode(PERMIT2)));

        // Deploys to 0x00000008412db3394C91A5CbD01635c6d140637C
        bytes32 salt = 0x9a269ec151cdb4159e40d33648400e3ac814791b0051656925f1f8b53831aab7;
        address liquidityLauncherAddress = Create2.computeAddress(salt, initCodeHash, DEFAULT_CREATE2_DEPLOYER);

        if (address(liquidityLauncherAddress).code.length > 0) {
            console.log("Skipping deployment of LiquidityLauncher as it already exists at", liquidityLauncherAddress);
            return;
        }

        vm.broadcast();
        LiquidityLauncher liquidityLauncher = new LiquidityLauncher{salt: salt}(IAllowanceTransfer(PERMIT2));

        console.log("LiquidityLauncher deployed to:", address(liquidityLauncher));
    }
}
