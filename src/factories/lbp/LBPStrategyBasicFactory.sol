// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Create2} from "@openzeppelin-latest/contracts/utils/Create2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {LBPStrategyBasic} from "@lbp/strategies/LBPStrategyBasic.sol";
import {MigratorParameters} from "../../types/MigratorParameters.sol";
import {LBPStrategyBaseFactory} from "./LBPStrategyBaseFactory.sol";

/// @title LBPStrategyBasicFactory
/// @notice Factory for the LBPStrategyBasic contract
/// @custom:security-contact security@uniswap.org
contract LBPStrategyBasicFactory is LBPStrategyBaseFactory {
    constructor(IPositionManager _positionManager, IPoolManager _poolManager)
        LBPStrategyBaseFactory(_positionManager, _poolManager)
    {}

    /// @inheritdoc LBPStrategyBaseFactory
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
