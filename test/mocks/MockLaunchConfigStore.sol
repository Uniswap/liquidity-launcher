// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LaunchConfig} from "../../src/interfaces/ILaunchHook.sol";

/// @notice Minimal launch-config holder standing in for a launch hook in module tests
contract MockLaunchConfigStore {
    mapping(PoolId poolId => LaunchConfig config) internal _launchConfigs;

    function setLaunchConfig(PoolId poolId, LaunchConfig memory config) external {
        _launchConfigs[poolId] = config;
    }

    function launchConfig(PoolId poolId) external view returns (LaunchConfig memory) {
        return _launchConfigs[poolId];
    }
}
