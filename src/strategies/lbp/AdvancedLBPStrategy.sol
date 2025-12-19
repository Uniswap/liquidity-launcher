// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {LBPStrategyBase} from "@lbp/strategies/LBPStrategyBase.sol";
import {MigrationData} from "../../types/MigrationData.sol";
import {MigratorParameters} from "../../types/MigratorParameters.sol";
import {BasePositionParams} from "../../types/PositionTypes.sol";
import {StrategyPlanner} from "../../libraries/StrategyPlanner.sol";
import {ActionsBuilder} from "../../libraries/ActionsBuilder.sol";
import {DynamicArrayLib} from "../../libraries/DynamicArrayLib.sol";
import {ParamsBuilder} from "../../libraries/ParamsBuilder.sol";

/// @title AdvancedLBPStrategy
/// @notice Basic Strategy to distribute tokens and raise funds from an auction to a v4 pool
/// @custom:security-contact security@uniswap.org
contract AdvancedLBPStrategy is LBPStrategyBase {
    using StrategyPlanner for BasePositionParams;
    using ActionsBuilder for bytes;
    using DynamicArrayLib for bytes[];

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
    function _createPositionPlan(MigrationData memory data) internal override returns (bytes memory plan) {
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

        bytes memory actions = ActionsBuilder.init().addMint().addSettle();
        bytes[] memory params = DynamicArrayLib.init()
            .append(baseParams.planFullRangePosition(data.initialTokenAmount, data.initialCurrencyAmount));
        params = params.append(ParamsBuilder.addSettleParam(currency)).append(ParamsBuilder.addSettleParam(poolToken));

        if (createOneSidedTokenPosition && reserveSupply > data.initialTokenAmount) {
            // Attempt to extend the position plan with a one sided token position
            // This will silently fail if the one sided position is invalid due to tick bounds or liquidity constraints
            // However, it will not revert the transaction as we sitll want to ensure the full range position can be created
            actions = actions.addMint();
            params = params.append(baseParams.planOneSidedPosition(reserveSupply - data.initialTokenAmount, 0));
        }

        // We encode a take pair action back to this contract for eventual sweeping by the operator
        actions = actions.addTakePair();
        params = params.append(baseParams.planFinalTakePair());

        return abi.encode(actions, params.truncate());
    }

    /// @notice Calculates the amount of tokens to transfer to the position manager
    /// @dev In the case where the one sided token position cannot be created, this will transfer too many tokens to POSM
    ///      however we will sweep the excess tokens back immediately after creating the positions.
    /// @param data Migration data
    /// @return The amount of tokens to transfer
    function _getTokenTransferAmount(MigrationData memory data) internal view override returns (uint128) {
        return reserveSupply > data.initialTokenAmount ? reserveSupply : data.initialTokenAmount;
    }

    /// @notice Calculates the amount of currency to transfer to the position manager
    /// @param data Migration data
    /// @return The amount of currency to transfer
    function _getCurrencyTransferAmount(MigrationData memory data) internal pure override returns (uint128) {
        return data.initialCurrencyAmount;
    }
}
