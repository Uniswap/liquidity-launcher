// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IDistributionStrategy} from "src/interfaces/IDistributionStrategy.sol";
import {IDistributionContract} from "src/interfaces/IDistributionContract.sol";
import {MockLBPInitializer} from "./MockLBPInitializer.sol";
import {AuctionParameters} from "@uniswap/continuous-clearing-auction/src/interfaces/IContinuousClearingAuction.sol";

contract MockInitializerFactory is IDistributionStrategy {
    MockLBPInitializer public deployedInitializer;

    address public strategyAddress;

    /// @notice If set, initializeDistribution returns this address instead of deploying a new one
    MockLBPInitializer public overrideInitializer;

    constructor(address _strategyAddress) {
        strategyAddress = _strategyAddress;
    }

    function setOverrideInitializer(MockLBPInitializer _initializer) external {
        overrideInitializer = _initializer;
    }

    function setStrategyAddress(address _strategyAddress) external {
        strategyAddress = _strategyAddress;
    }

    function initializeDistribution(address token, uint256 amount, bytes calldata configData, bytes32)
        external
        returns (IDistributionContract)
    {
        AuctionParameters memory params = abi.decode(configData, (AuctionParameters));

        MockLBPInitializer initializer;
        if (address(overrideInitializer) != address(0)) {
            initializer = overrideInitializer;
        } else {
            initializer = new MockLBPInitializer(
                token,
                params.currency,
                uint128(amount),
                params.tokensRecipient,
                params.fundsRecipient,
                params.startBlock,
                params.endBlock
            );
        }

        deployedInitializer = initializer;
        return IDistributionContract(address(initializer));
    }
}
