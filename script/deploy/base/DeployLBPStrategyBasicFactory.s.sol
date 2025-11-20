// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {LBPStrategyBasicFactory} from "../../../src/distributionStrategies/LBPStrategyBasicFactory.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

contract DeployLBPStrategyBasicFactoryBaseScript is Script {
    // Unichain addresses: https://docs.uniswap.org/contracts/v4/deployments#base-8453
    address public constant POSITION_MANAGER = 0x7C5f5A4bBd8fD63184577525326123B519429bDc;
    address public constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;

    function run() public {
        vm.startBroadcast();
        // Deploys to 0xC46143aE2801b21B8C08A753f9F6b52bEaD9C134
        LBPStrategyBasicFactory factory = new LBPStrategyBasicFactory{salt: bytes32(0)}(
            IPositionManager(POSITION_MANAGER), IPoolManager(POOL_MANAGER)
        );

        console.log("LBPStrategyBasicFactory deployed to:", address(factory));
        vm.stopBroadcast();
    }
}
