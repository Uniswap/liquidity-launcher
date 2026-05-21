// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {LBPStrategy} from "src/strategies/lbp/LBPStrategy.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IDistributionStrategy} from "src/interfaces/IDistributionStrategy.sol";
import {Parameters, DeployParameters} from "./Parameters.sol";

/// @title DeployLBPStrategyScript
/// @notice Deploys the LBPStrategy singleton
contract DeployLBPStrategyScript is Script, Parameters {
    function run(IDistributionStrategy initializerFactory, uint256 recoveryDelayBlocks) public {
        DeployParameters memory params = getParameters(block.chainid);

        vm.broadcast();
        LBPStrategy lbpStrategy =
            new LBPStrategy(params.positionManager, params.poolManager, initializerFactory, recoveryDelayBlocks);

        console.log("LBPStrategy deployed to:", address(lbpStrategy));
    }
}
