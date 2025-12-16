// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Create2} from "@openzeppelin-latest/contracts/utils/Create2.sol";
import {LBPStrategyBaseFactory} from "./LBPStrategyBaseFactory.sol";
import {FullRangeLBPStrategy} from "../distributionContracts/FullRangeLBPStrategy.sol";
import {MigratorParameters} from "../types/MigratorParameters.sol";

/// @title FullRangeLBPStrategyFactory
/// @notice Factory for the FullRangeLBPStrategy contract
/// @custom:security-contact security@uniswap.org
contract FullRangeLBPStrategyFactory is LBPStrategyBaseFactory {
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

        (MigratorParameters memory migratorParams, bytes memory auctionParams) =
            abi.decode(configData, (MigratorParameters, bytes));

        deployedBytecode = abi.encodePacked(
            type(FullRangeLBPStrategy).creationCode,
            abi.encode(token, uint128(totalSupply), migratorParams, auctionParams, positionManager, poolManager)
        );
    }
}
