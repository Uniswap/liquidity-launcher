// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {LBPStrategyBase} from "@lbp/strategies/LBPStrategyBase.sol";
import {MigrationData} from "../../types/MigrationData.sol";
import {MigratorParameters} from "../../types/MigratorParameters.sol";
import {BasePositionParams, FullRangeParams} from "../../types/PositionTypes.sol";
import {ParamsBuilder} from "../../libraries/ParamsBuilder.sol";
import {StrategyPlanner} from "../../libraries/StrategyPlanner.sol";
import {DynamicArray} from "../../libraries/DynamicArray.sol";

/// @title FullRangeLBPStrategy
/// @notice Strategy to initialize a Uniswap v4 pool and migrate the tokens and raised funds into a full range position
/// @custom:security-contact security@uniswap.org
contract FullRangeLBPStrategy is LBPStrategyBase {
    using StrategyPlanner for BasePositionParams;
    using ParamsBuilder for bytes[];
    using DynamicArray for bytes[];

    constructor(
        address _token,
        uint128 _totalSupply,
        MigratorParameters memory _migratorParams,
        bytes memory _auctionParams,
        IPositionManager _positionManager,
        IPoolManager _poolManager
    ) LBPStrategyBase(_token, _totalSupply, _migratorParams, _auctionParams, _positionManager, _poolManager) {}

    /// @notice Creates the position plan based on migration data
    /// @param data Migration data with all necessary parameters
    /// @return plan The encoded position plan
    function _createPositionPlan(MigrationData memory data) internal override returns (bytes memory plan) {
        bytes memory actions;
        bytes[] memory params;

        address poolToken = getPoolToken();

        // Create base parameters
        BasePositionParams memory baseParams = BasePositionParams({
            currency: currency,
            poolToken: poolToken,
            poolLPFee: poolLPFee,
            poolTickSpacing: poolTickSpacing,
            initialSqrtPriceX96: data.sqrtPriceX96,
            liquidity: data.liquidity,
            positionRecipient: positionRecipient,
            hooks: IHooks(address(this))
        });

        (actions, params) = StrategyPlanner.planFullRangePosition(
            actions,
            params,
            baseParams,
            FullRangeParams({tokenAmount: data.initialTokenAmount, currencyAmount: data.initialCurrencyAmount})
        );

        (actions, params) = StrategyPlanner.planFinalTakePair(actions, params, baseParams);

        return abi.encode(actions, params.truncate());
    }

    /// @notice Calculates the amount of tokens to transfer
    /// @param data Migration data
    /// @return The amount of tokens to transfer to the position manager
    function _getTokenTransferAmount(MigrationData memory data) internal pure override returns (uint128) {
        return data.initialTokenAmount;
    }

    /// @notice Calculates the amount of currency to transfer
    /// @param data Migration data
    /// @return The amount of currency to transfer to the position manager
    function _getCurrencyTransferAmount(MigrationData memory data) internal pure override returns (uint128) {
        return data.initialCurrencyAmount;
    }
}
