// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {LBPStrategyBasic} from "@lbp/strategies/LBPStrategyBasic.sol";
import {MigratorParameters} from "../../types/MigratorParameters.sol";
import {StrategyFactory} from "../StrategyFactory.sol";

/// @title LBPStrategyBasicFactory
/// @notice Factory for the LBPStrategyBasic contract
/// @custom:security-contact security@uniswap.org
contract LBPStrategyBasicFactory is StrategyFactory {
    /// @notice The position manager that will be used to create the position
    IPositionManager public immutable positionManager;
    /// @notice The pool manager that will be used to create the pool
    IPoolManager public immutable poolManager;

    constructor(IPositionManager _positionManager, IPoolManager _poolManager) {
        positionManager = _positionManager;
        poolManager = _poolManager;
    }

    /// @inheritdoc StrategyFactory
    /// @dev Reverts if the total supply is greater than uint128.max
    function _validateParamsAndReturnDeployedBytecode(address token, uint256 totalSupply, bytes calldata configData)
        internal
        view
        override
        returns (bytes memory deployedBytecode)
    {
        if (totalSupply > type(uint128).max) revert InvalidAmount(totalSupply, type(uint128).max);

        (
            MigratorParameters memory migratorParams,
            bytes memory auctionParams,
            bool createOneSidedTokenPosition,
            bool createOneSidedCurrencyPosition
        ) = abi.decode(configData, (MigratorParameters, bytes, bool, bool));

        deployedBytecode = abi.encodePacked(
            type(LBPStrategyBasic).creationCode,
            abi.encode(
                token,
                uint128(totalSupply),
                migratorParams,
                auctionParams,
                positionManager,
                poolManager,
                createOneSidedTokenPosition,
                createOneSidedCurrencyPosition
            )
        );
    }
}
