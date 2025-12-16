// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {BaseStrategyFactory} from "../BaseStrategyFactory.sol";

/// @title BaseLBPStrategyFactory
/// @notice Base factory for LBPStrategy contracts with overridable deployment logic
/// @custom:security-contact security@uniswap.org
abstract contract BaseLBPStrategyFactory is BaseStrategyFactory {
    /// @notice The position manager that will be used to create the position
    IPositionManager public immutable positionManager;
    /// @notice The pool manager that will be used to create the pool
    IPoolManager public immutable poolManager;

    constructor(IPositionManager _positionManager, IPoolManager _poolManager) {
        positionManager = _positionManager;
        poolManager = _poolManager;
    }
}
