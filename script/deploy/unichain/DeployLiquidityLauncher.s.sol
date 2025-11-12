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

        bytes32 salt = 0x9a269ec151cdb4159e40d33648400e3ac814791b0051656925f1f8b53831aab7;
        LiquidityLauncher liquidityLauncher = new LiquidityLauncher{salt: salt}(IAllowanceTransfer(PERMIT2));

        console.log("LiquidityLauncher deployed to:", address(liquidityLauncher));
        vm.stopBroadcast();
    }
}
