// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {AdvancedLBPStrategyFactory} from "@lbp/factories/AdvancedLBPStrategyFactory.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

contract DeployAdvancedLBPStrategyFactoryUnichainScript is Script {
    // Unichain addresses: https://docs.uniswap.org/contracts/v4/deployments#unichain-130
    address public constant POSITION_MANAGER = 0x4529A01c7A0410167c5740C487A8DE60232617bf;
    address public constant POOL_MANAGER = 0x1F98400000000000000000000000000000000004;

    function run() public {
        vm.startBroadcast();
        // Deploys to 0x435DDCFBb7a6741A5Cc962A95d6915EbBf60AE24
        AdvancedLBPStrategyFactory factory = new AdvancedLBPStrategyFactory{salt: bytes32(0)}(
            IPositionManager(POSITION_MANAGER), IPoolManager(POOL_MANAGER)
        );

        console.log("AdvancedLBPStrategyFactory deployed to:", address(factory));
        vm.stopBroadcast();
    }
}
