// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {GovernedLBPStrategyFactory} from "../../../src/distributionStrategies/GovernedLBPStrategyFactory.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

contract DeployGovernedLBPStrategyFactorySepoliaScript is Script {
    // Mainnet addresses: https://docs.uniswap.org/contracts/v4/deployments#sepolia-11155111
    address public constant POSITION_MANAGER = 0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4;
    address public constant POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;

    function run() public {
        vm.startBroadcast();

        bytes32 initCodeHash = keccak256(
            abi.encodePacked(type(GovernedLBPStrategyFactory).creationCode, abi.encode(POSITION_MANAGER, POOL_MANAGER))
        );
        console.logBytes32(initCodeHash);

        // Deploys to 0xC695ee292c39Be6a10119C70Ed783d067fcecfA4
        bytes32 salt = 0x684f68d3f04ef55523dedd9d317f479d09ba3da998d0696023381882adc021ad;

        GovernedLBPStrategyFactory factory =
            new GovernedLBPStrategyFactory{salt: salt}(IPositionManager(POSITION_MANAGER), IPoolManager(POOL_MANAGER));

        console.log("GovernedLBPStrategyFactory deployed to:", address(factory));
        vm.stopBroadcast();
    }
}
