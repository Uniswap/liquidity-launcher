// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BasePositionParams, OneSidedParams} from "../types/PositionTypes.sol";
import {ParamsBuilder} from "../libraries/ParamsBuilder.sol";
import {MigrationData} from "../types/MigrationData.sol";
import {LBPStrategyBase} from "./LBPStrategyBase.sol";
import {MigratorParameters} from "../types/MigratorParameters.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {StrategyPlanner} from "../libraries/StrategyPlanner.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ILBPStrategyBasic} from "../interfaces/ILBPStrategyBasic.sol";

/// @title LBPStrategyBasic
/// @notice Basic Strategy to distribute tokens and raise funds from an auction to a v4 pool
/// @custom:security-contact security@uniswap.org
contract LBPStrategyBasic is ILBPStrategyBasic, LBPStrategyBase {
    using StrategyPlanner for BasePositionParams;

    /// @notice Whether to create a one sided position in the token after the full range position
    bool public immutable createOneSidedTokenPosition;
    /// @notice Whether to create a one sided position in the currency after the full range position
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
    function _createPositionPlan(MigrationData memory data) internal view override returns (bytes memory plan) {
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

        if (
            createOneSidedTokenPosition && reserveSupply > data.initialTokenAmount || createOneSidedCurrencyPosition
                && data.leftoverCurrency > 0
        ) {
            (actions, params) = _createFullRangePositionPlan(
                baseParams,
                data.initialTokenAmount,
                data.initialCurrencyAmount,
                ParamsBuilder.FULL_RANGE_WITH_ONE_SIDED_SIZE
            );
            (actions, params) = _createOneSidedPositionPlan(
                baseParams, actions, params, data.initialTokenAmount, data.leftoverCurrency
            );
            // shouldCreatedOneSided could be true, but if the one sided position is not valid, only a full range position will be created and there will be no one sided params
            data.hasOneSidedParams = params.length == ParamsBuilder.FULL_RANGE_WITH_ONE_SIDED_SIZE;
        } else {
            (actions, params) = _createFullRangePositionPlan(
                baseParams, data.initialTokenAmount, data.initialCurrencyAmount, ParamsBuilder.FULL_RANGE_SIZE
            );
        }

        (actions, params) = baseParams.planFinalTakePair(actions, params);

        return abi.encode(actions, params);
    }

    /// @notice Calculates the amount of tokens to transfer
    /// @param data Migration data
    /// @return The amount of tokens to transfer to the position manager
    function _getTokenTransferAmount(MigrationData memory data) internal view override returns (uint128) {
        // hasOneSidedParams can only be true if shouldCreateOneSided is true
        return
            (reserveSupply > data.initialTokenAmount && data.hasOneSidedParams)
                ? reserveSupply
                : data.initialTokenAmount;
    }

    /// @notice Calculates the amount of currency to transfer
    /// @param data Migration data
    /// @return The amount of currency to transfer to the position manager
    function _getCurrencyTransferAmount(MigrationData memory data) internal pure override returns (uint128) {
        // hasOneSidedParams can only be true if shouldCreateOneSided is true
        return (data.leftoverCurrency > 0 && data.hasOneSidedParams)
            ? data.initialCurrencyAmount + data.leftoverCurrency
            : data.initialCurrencyAmount;
    }

    /// @notice Creates the plan for creating a one sided v4 position using the position manager along with the full range position
    /// @param baseParams The base parameters for the position
    /// @param actions The existing actions for the full range position which may be extended with the new actions for the one sided position
    /// @param params The existing parameters for the full range position which may be extended with the new parameters for the one sided position
    /// @param tokenAmount The amount of token to be used to create the position
    /// @param leftoverCurrency The amount of currency that was leftover from the full range position
    /// @return The actions and parameters needed to create the full range position and the one sided position
    function _createOneSidedPositionPlan(
        BasePositionParams memory baseParams,
        bytes memory actions,
        bytes[] memory params,
        uint128 tokenAmount,
        uint128 leftoverCurrency
    ) private view returns (bytes memory, bytes[] memory) {
        // reserveSupply - tokenAmount will not underflow because of validation in TokenPricing.calculateAmounts()
        uint128 amount = leftoverCurrency > 0 ? leftoverCurrency : reserveSupply - tokenAmount;
        bool inToken = leftoverCurrency == 0;

        // Create one-sided specific parameters
        OneSidedParams memory oneSidedParams = OneSidedParams({amount: amount, inToken: inToken});

        // Plan the one-sided position
        return baseParams.planOneSidedPosition(oneSidedParams, actions, params);
    }
}
