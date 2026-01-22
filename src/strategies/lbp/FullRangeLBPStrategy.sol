// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {LBPStrategyBase} from "@lbp/strategies/LBPStrategyBase.sol";
import {MigrationData} from "../../types/MigrationData.sol";
import {MigratorParameters} from "../../types/MigratorParameters.sol";
import {BasePositionParams, FullRangeParams} from "../../types/PositionTypes.sol";
import {Plan, StrategyPlanner} from "../../libraries/StrategyPlanner.sol";

/// @title FullRangeLBPStrategy
/// @notice Strategy to initialize a Uniswap v4 pool and migrate the tokens and raised funds into a full range position
/// @custom:security-contact security@uniswap.org
contract FullRangeLBPStrategy is LBPStrategyBase {
    using StrategyPlanner for *;

    constructor(
        address _token,
        uint128 _totalSupply,
        MigratorParameters memory _migratorParams,
        bytes memory _initializerParams,
        IPositionManager _positionManager,
        IPoolManager _poolManager
    ) LBPStrategyBase(_token, _totalSupply, _migratorParams, _initializerParams, _positionManager, _poolManager) {}

    /// @notice Creates the position plan based on migration data
    /// @param _data Migration data with all necessary parameters
    /// @return plan The encoded position plan
    function _createPositionPlan(MigrationData memory _data) internal view override returns (bytes memory) {
        Plan memory plan = StrategyPlanner.init();

        // Create base parameters
        BasePositionParams memory baseParams = _basePositionParams(_data);

        plan = plan.planFullRangePosition(
            baseParams,
            FullRangeParams({tokenAmount: _data.fullRangeTokenAmount, currencyAmount: _data.fullRangeCurrencyAmount})
        );

        plan = plan.planTakePair(baseParams);

        return plan.encode();
    }

    /// @notice Calculates the amount of tokens to transfer
    /// @param _data Migration data
    /// @return The amount of tokens to transfer to the position manager
    function _getTokenTransferAmount(MigrationData memory _data) internal pure override returns (uint128) {
        return _data.fullRangeTokenAmount;
    }

    /// @notice Calculates the amount of currency to transfer
    /// @param _data Migration data
    /// @return The amount of currency to transfer to the position manager
    function _getCurrencyTransferAmount(MigrationData memory _data) internal pure override returns (uint128) {
        return _data.fullRangeCurrencyAmount;
    }
}
