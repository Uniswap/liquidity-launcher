// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {LiquidityLauncher} from "../../../src/LiquidityLauncher.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

contract DeployLiquidityLauncherUnichainScript is Script {
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    function run() public {
        vm.startBroadcast();
        LiquidityLauncher liquidityLauncher = new LiquidityLauncher(IAllowanceTransfer(PERMIT2));

        console.log("LiquidityLauncher deployed to:", address(liquidityLauncher));
        vm.stopBroadcast();
    }
}
