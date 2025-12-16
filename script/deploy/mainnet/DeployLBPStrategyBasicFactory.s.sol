// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {LBPStrategyBasicFactory} from "@lbp/factories/LBPStrategyBasicFactory.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

contract DeployLBPStrategyBasicFactoryMainnetScript is Script {
    // Mainnet addresses: https://docs.uniswap.org/contracts/v4/deployments#ethereum-1
    address public constant POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address public constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    function run() public {
        vm.startBroadcast();

        // Deploys to 0xbbbb6FFaBCCb1EaFD4F0baeD6764d8aA973316B6
        bytes32 salt = 0x01c060ffc9170f076aaac7c78517249d29a55dc0cb034c43fa6461d737ce198b;

        LBPStrategyBasicFactory factory =
            new LBPStrategyBasicFactory{salt: salt}(IPositionManager(POSITION_MANAGER), IPoolManager(POOL_MANAGER));

        console.log("LBPStrategyBasicFactory deployed to:", address(factory));
        vm.stopBroadcast();
    }
}
