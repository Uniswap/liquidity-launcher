// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IDistributionStrategy} from "src/interfaces/IDistributionStrategy.sol";
import {IDistributionContract} from "src/interfaces/IDistributionContract.sol";
import {MockLBPInitializer} from "./MockLBPInitializer.sol";

/// @notice Mock factory that deploys MockLBPInitializers
contract MockInitializerFactory is IDistributionStrategy {
    MockLBPInitializer public deployedInitializer;

    address public strategyAddress;
    uint128 public custodyTokensOverride;

    constructor(address _strategyAddress) {
        strategyAddress = _strategyAddress;
    }

    function setStrategyAddress(address _strategyAddress) external {
        strategyAddress = _strategyAddress;
    }

    /// @notice Set the custodyTokens value that deployed initializers will report
    function setCustodyTokens(uint128 _custodyTokens) external {
        custodyTokensOverride = _custodyTokens;
    }

    function initializeDistribution(address token, uint256, bytes calldata, bytes32)
        external
        returns (IDistributionContract)
    {
        MockLBPInitializer initializer = new MockLBPInitializer(
            token, address(0), 0, custodyTokensOverride, strategyAddress, strategyAddress, 0, uint64(block.number) + 50
        );

        deployedInitializer = initializer;
        return IDistributionContract(address(initializer));
    }
}
