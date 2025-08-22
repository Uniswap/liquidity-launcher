// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IDistributionStrategy} from "../../src/interfaces/IDistributionStrategy.sol";
import {IDistributionContract} from "../../src/interfaces/IDistributionContract.sol";
import {MockDistributionContract} from "./MockDistributionContract.sol";

contract MockDistributionStrategy is IDistributionStrategy {
    function initializeDistribution(address, uint256, bytes calldata)
        external
        override
        returns (IDistributionContract distributionContract)
    {
        return IDistributionContract(address(new MockDistributionContract()));
    }
}
