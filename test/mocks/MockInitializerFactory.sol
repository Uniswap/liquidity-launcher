// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IDistributor} from "src/interfaces/IDistributor.sol";
import {IDistributorFactory} from "src/interfaces/IDistributorFactory.sol";
import {MockLBPInitializer} from "./MockLBPInitializer.sol";
import {LBPInitializationParams} from "src/interfaces/ILBPInitializer.sol";

/// @notice Mock factory that deploys MockLBPInitializers
contract MockInitializerFactory is IDistributorFactory {
    MockLBPInitializer public deployedInitializer;

    address public strategyAddress;
    address public tokensRecipient;

    /// @notice If set, create returns this address instead of deploying a new one
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

    function setTokensRecipient(address _tokensRecipient) external {
        tokensRecipient = _tokensRecipient;
    }

    function create(address token, uint256 amount, bytes calldata configData, bytes32 salt)
        external
        override
        returns (IDistributor)
    {
        salt;
        (uint64 endBlock, address currency, LBPInitializationParams memory lbpParams) =
            abi.decode(configData, (uint64, address, LBPInitializationParams));

        MockLBPInitializer initializer;
        if (address(overrideInitializer) != address(0)) {
            initializer = overrideInitializer;
        } else {
            initializer =
                new MockLBPInitializer(token, currency, uint128(amount), tokensRecipient, strategyAddress, 0, endBlock);
            initializer.setLbpInitializationParams(lbpParams);
        }

        deployedInitializer = initializer;
        return IDistributor(address(initializer));
    }

    function getAddress(address, uint256, bytes calldata, bytes32) external view override returns (IDistributor) {
        return IDistributor(address(deployedInitializer));
    }
}
