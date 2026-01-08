// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {LBPStrategyBase} from "@lbp/strategies/LBPStrategyBase.sol";
import {MigrationData} from "../../types/MigrationData.sol";
import {MigratorParameters} from "../../types/MigratorParameters.sol";
import {BasePositionParams, OneSidedParams, FullRangeParams} from "../../types/PositionTypes.sol";
import {Plan, StrategyPlanner} from "../../libraries/StrategyPlanner.sol";

/// @title AdvancedLBPStrategy
/// @notice Basic Strategy to distribute tokens and raise funds from an auction to a v4 pool
/// @custom:security-contact security@uniswap.org
contract AdvancedLBPStrategy is LBPStrategyBase {
    using StrategyPlanner for *;

    bool public immutable createOneSidedTokenPosition;
    bool public immutable createOneSidedCurrencyPosition;

    constructor(
        address _token,
        uint128 _totalSupply,
        MigratorParameters memory _migratorParams,
        bytes memory _auctionParams,
        IPositionManager _positionManager,
        IPoolManager _poolManager,
        bool _createOneSidedTokenPosition,
        bool _createOneSidedCurrencyPosition
    ) LBPStrategyBase(_token, _totalSupply, _migratorParams, _auctionParams, _positionManager, _poolManager) {
        createOneSidedTokenPosition = _createOneSidedTokenPosition;
        createOneSidedCurrencyPosition = _createOneSidedCurrencyPosition;
    }

    /// @notice Creates the position plan based on migration data
    /// @param data Migration data with all necessary parameters
    /// @return plan The encoded position plan
    function _createPositionPlan(MigrationData memory data) internal override returns (bytes memory) {
        Plan memory plan = StrategyPlanner.init();

        // Create base parameters
        BasePositionParams memory baseParams = _basePositionParams(data);

        plan = plan.planFullRangePosition(
            baseParams,
            FullRangeParams({tokenAmount: data.initialTokenAmount, currencyAmount: data.initialCurrencyAmount})
        );

        if (createOneSidedTokenPosition && reserveSupply > data.initialTokenAmount) {
            // reserveSupply - tokenAmount will not underflow because of validation in TokenPricing.calculateAmounts()
            uint128 amount = reserveSupply - data.initialTokenAmount;
            // Create one-sided specific parameters
            OneSidedParams memory oneSidedParams = OneSidedParams({amount: amount, inToken: true});

            // Attempt to extend the position plan with a one sided token position
            // This will silently fail if the one sided position is invalid due to tick bounds or liquidity constraints
            // However, it will not revert the transaction as we still want to ensure the full range position can be created
            plan = plan.planOneSidedPosition(baseParams, oneSidedParams);
        }

        if (createOneSidedCurrencyPosition && data.leftoverCurrency > 0) {
            // Create one-sided specific parameters
            OneSidedParams memory oneSidedParams = OneSidedParams({amount: data.leftoverCurrency, inToken: false});

            // Attempt to extend the position plan with a one sided currency position
            // This will silently fail if the one sided position is invalid due to tick bounds or liquidity constraints
            // However, it will not revert the transaction as we still want to ensure the full range position can be created
            plan = plan.planOneSidedPosition(baseParams, oneSidedParams);
        }

        // We encode a take pair action back to this contract for eventual sweeping by the operator
        plan = plan.planTakePair(baseParams);

        return plan.encode();
    }

    /// @notice Calculates the amount of tokens to transfer to the position manager
    /// @dev In the case where the one sided token position cannot be created, this will transfer too many tokens to POSM
    ///      however we will sweep the excess tokens back immediately after creating the positions.
    /// @param data Migration data
    /// @return The amount of tokens to transfer
    function _getTokenTransferAmount(MigrationData memory data) internal view override returns (uint128) {
        return (createOneSidedTokenPosition && reserveSupply > data.initialTokenAmount)
            ? reserveSupply
            : data.initialTokenAmount;
    }

    /// @notice Calculates the amount of currency to transfer to the position manager
    /// @param data Migration data
    /// @return The amount of currency to transfer
    function _getCurrencyTransferAmount(MigrationData memory data) internal view override returns (uint128) {
        return (createOneSidedCurrencyPosition && data.leftoverCurrency > 0)
            ? data.initialCurrencyAmount + data.leftoverCurrency
            : data.initialCurrencyAmount;
    }
}
