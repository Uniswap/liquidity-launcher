// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IDistributionStrategy} from "../../src/interfaces/IDistributionStrategy.sol";
import {IDistributionContract} from "../../src/interfaces/IDistributionContract.sol";

contract MockDistributionStrategyAndContract is IDistributionStrategy, IDistributionContract {
    function initializeDistribution(address, uint128, bytes calldata, bytes32)
        external
        view
        override
        returns (IDistributionContract distributionContract)
    {
        return IDistributionContract(address(this));
    }

    function onTokensReceived() external {}
}
