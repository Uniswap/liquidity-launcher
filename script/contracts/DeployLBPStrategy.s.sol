// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {LBPStrategy} from "../../src/strategies/lbp/LBPStrategy.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IDistributorFactory} from "../../src/interfaces/IDistributorFactory.sol";
import {Parameters, DeployParameters} from "./Parameters.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

/// @title DeployLBPStrategyScript
/// @notice Deploys the LBPStrategy singleton
contract DeployLBPStrategyScript is Script, Parameters {
    function run(IDistributorFactory initializerFactory) public returns (address) {
        DeployParameters memory params = getParameters(block.chainid);

        bytes memory bytecode = abi.encodePacked(
            type(LBPStrategy).creationCode, abi.encode(params.positionManager, params.poolManager, initializerFactory)
        );
        bytes32 initCodeHash = keccak256(bytecode);

        address expectedAddress;
        bytes32 salt;
        // If a salt is provided, use it to compute the expected address
        if (params.salt != bytes32(0)) {
            expectedAddress = Create2.computeAddress(params.salt, initCodeHash, DEFAULT_CREATE2_DEPLOYER);
            salt = params.salt;
        } else {
            // Otherwise, mine a salt that will produce a valid v4 hook address
            (address foundAddress, bytes32 foundSalt) = HookMiner.find(
                DEFAULT_CREATE2_DEPLOYER,
                DEFAULT_HOOK_FLAGS,
                type(LBPStrategy).creationCode,
                abi.encode(params.positionManager, params.poolManager, initializerFactory)
            );
            console.logBytes32(foundSalt);
            expectedAddress = foundAddress;
            salt = foundSalt;
        }

        if (expectedAddress.code.length > 0) {
            console.log("Skipping deployment of LBPStrategy as it already exists at", expectedAddress);
            return expectedAddress;
        }

        vm.broadcast();
        LBPStrategy lbpStrategy =
            new LBPStrategy{salt: salt}(params.positionManager, params.poolManager, initializerFactory);

        console.log("LBPStrategy deployed to:", address(lbpStrategy));
        require(address(lbpStrategy).code.length > 0, "LBPStrategy deployment failed");
        return address(lbpStrategy);
    }
}
