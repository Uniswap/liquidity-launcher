// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IDistributionStrategy} from "../interfaces/IDistributionStrategy.sol";
import {IDistributionContract} from "../interfaces/IDistributionContract.sol";
import {BasicMigrator} from "../distributionContracts/BasicMigrator.sol";

contract BasicMigratorFactory is IDistributionStrategy {
    function initializeDistribution(bytes calldata configData) external returns (IDistributionContract basicMigrator) {
        basicMigrator = IDistributionContract(address(new BasicMigrator{salt: keccak256(abi.encode(configData))}()));
    }
}
