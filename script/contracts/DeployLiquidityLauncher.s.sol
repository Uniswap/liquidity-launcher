// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {LiquidityLauncher} from "../../src/LiquidityLauncher.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {Parameters} from "./Parameters.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

/// @title DeployLiquidityLauncherScript
/// @notice Since LiquidityLauncher takes no chain dependent parameters it can be deployed to the same address on all chains
contract DeployLiquidityLauncherScript is Script, Parameters {
    function run() public returns (address liquidityLauncherAddress) {
        bytes32 initCodeHash = keccak256(abi.encodePacked(type(LiquidityLauncher).creationCode, abi.encode(PERMIT2)));

        console.logBytes32(initCodeHash);

        // bytes32 salt = vm.envOr("GLOBAL_SALT", bytes32(0));
        // Deploys to 0x0000FffFBE8efE702c8703aE3477FF5dE3d319C0
        bytes32 salt = 0xa8dfc290629f36db19306c77eb23c1b4f8a90d841bfb07158e8e6f752064de39;
        liquidityLauncherAddress = Create2.computeAddress(salt, initCodeHash, DEFAULT_CREATE2_DEPLOYER);

        if (liquidityLauncherAddress.code.length > 0) {
            console.log("Skipping deployment of LiquidityLauncher as it already exists at", liquidityLauncherAddress);
            return liquidityLauncherAddress;
        }

        vm.broadcast();
        LiquidityLauncher liquidityLauncher = new LiquidityLauncher{salt: salt}(IAllowanceTransfer(PERMIT2));
        liquidityLauncherAddress = address(liquidityLauncher);

        console.log("LiquidityLauncher deployed to:", liquidityLauncherAddress);
    }
}
