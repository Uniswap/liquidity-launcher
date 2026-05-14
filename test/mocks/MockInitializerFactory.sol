// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IDistributionStrategy} from "src/interfaces/IDistributionStrategy.sol";
import {IDistributionContract} from "src/interfaces/IDistributionContract.sol";
import {MockLBPInitializer} from "./MockLBPInitializer.sol";

/// @notice Mock factory that deploys MockLBPInitializers.
/// Reads endBlock from the configData bytes, mirroring how the real CCA factory
/// reads AuctionParameters from configData. The initializer's totalSupply is set
/// from the `amount` argument (auctionSupply), matching CCA factory behavior.
contract MockInitializerFactory is IDistributionStrategy {
    MockLBPInitializer public deployedInitializer;

    address public strategyAddress;
    address public currencyOverride;

    /// @notice If set, initializeDistribution returns this address instead of deploying a new one
    MockLBPInitializer public overrideInitializer;

    constructor(address _strategyAddress) {
        strategyAddress = _strategyAddress;
    }

    function setOverrideInitializer(MockLBPInitializer _initializer) external {
        overrideInitializer = _initializer;
    }

    function setCurrencyOverride(address _currency) external {
        currencyOverride = _currency;
    }

    function setStrategyAddress(address _strategyAddress) external {
        strategyAddress = _strategyAddress;
    }

    function initializeDistribution(address token, uint256 amount, bytes calldata configData, bytes32)
        external
        returns (IDistributionContract)
    {
        uint64 endBlock = abi.decode(configData, (uint64));

        MockLBPInitializer initializer;
        if (address(overrideInitializer) != address(0)) {
            initializer = overrideInitializer;
        } else {
            initializer = new MockLBPInitializer(
                token, currencyOverride, uint128(amount), strategyAddress, strategyAddress, 0, endBlock
            );
        }

        deployedInitializer = initializer;
        return IDistributionContract(address(initializer));
    }
}
