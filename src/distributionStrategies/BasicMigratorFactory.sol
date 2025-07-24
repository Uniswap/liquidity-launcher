// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IDistributionStrategy} from "../interfaces/IDistributionStrategy.sol";
import {IDistributionContract} from "../interfaces/IDistributionContract.sol";
import {BasicMigrator} from "../distributionContracts/BasicMigrator.sol";
import {MigratorParameters} from "../types/MigratorParams.sol";

contract BasicMigratorFactory is IDistributionStrategy {
    function initializeDistribution(bytes calldata configData) external returns (IDistributionContract basicMigrator) {
        MigratorParameters memory parameters = abi.decode(configData, (MigratorParameters));
        bytes32 salt = keccak256(configData);

        basicMigrator = IDistributionContract(address(new BasicMigrator{salt: salt}(parameters)));
    }
}
