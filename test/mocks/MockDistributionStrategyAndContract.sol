// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IDistributionContract} from 'src/interfaces/IDistributionContract.sol';
import {IDistributionStrategy} from 'src/interfaces/IDistributionStrategy.sol';

contract MockDistributionStrategyAndContract is IDistributionStrategy, IDistributionContract {
    function initializeDistribution(address, uint256, bytes calldata, bytes32)
        external
        view
        override
        returns (IDistributionContract distributionContract)
    {
        return IDistributionContract(address(this));
    }

    function onTokensReceived() external {}
}
