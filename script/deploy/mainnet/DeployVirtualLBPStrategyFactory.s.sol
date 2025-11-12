// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {VirtualLBPStrategyFactory} from "../../../src/distributionStrategies/VirtualLBPStrategyFactory.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

contract DeployVirtualLBPStrategyFactoryMainnetScript is Script {
    // Mainnet addresses: https://docs.uniswap.org/contracts/v4/deployments#ethereum-1
    address public constant POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address public constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    function run() public {
        vm.startBroadcast();

        bytes32 initCodeHash = keccak256(abi.encodePacked(type(VirtualLBPStrategyFactory).creationCode, abi.encode(POSITION_MANAGER, POOL_MANAGER)));
        console.logBytes32(initCodeHash);

        // Deploys to 0x00000010F37b6524617b17e66796058412bbC487
        bytes32 salt = 0x684f68d3f04ef55523dedd9d317f479d09ba3da998d0696023381882adc021ad;

        VirtualLBPStrategyFactory factory = new VirtualLBPStrategyFactory{salt: salt}(
            IPositionManager(POSITION_MANAGER), IPoolManager(POOL_MANAGER)
        );

        console.log("VirtualLBPStrategyFactory deployed to:", address(factory));
        vm.stopBroadcast();
    }
}
