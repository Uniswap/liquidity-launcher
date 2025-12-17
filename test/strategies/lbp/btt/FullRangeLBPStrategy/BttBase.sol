// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base} from "../Base.sol";
import {FullRangeLBPStrategy} from "src/strategies/lbp/FullRangeLBPStrategy.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {MigratorParameters} from "src/types/MigratorParameters.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/// @title BttBase
/// @notice Base contract for testing the FullRangeLBPStrategy contract
abstract contract BttBase is Base {
    /// @inheritdoc Base
    function _getHookAddress() internal override returns (address) {
        return
            address(
                uint160(uint256(type(uint160).max) & CLEAR_ALL_HOOK_PERMISSIONS_MASK | Hooks.BEFORE_INITIALIZE_FLAG)
            );
    }

    /// @notice Returns the bytecode for the FullRangeLBPStrategy contract
    function _getBytecode(
        address token,
        uint128 totalSupply,
        MigratorParameters memory migratorParams,
        bytes memory auctionParams,
        IPositionManager positionManager,
        IPoolManager poolManager
    ) internal view returns (bytes memory) {
        return abi.encodePacked(
            type(FullRangeLBPStrategy).creationCode,
            abi.encode(token, totalSupply, migratorParams, auctionParams, positionManager, poolManager)
        );
    }

    /// @notice Deploy a FullRangeLBPStrategy contract
    function _deployFullRangeLBPStrategy(
        address token,
        uint128 totalSupply,
        MigratorParameters memory migratorParams,
        bytes memory auctionParams
    ) internal {
        bytes memory bytecode = _getBytecode(
            token,
            totalSupply,
            migratorParams,
            auctionParams,
            IPositionManager(POSITION_MANAGER),
            IPoolManager(POOL_MANAGER)
        );
        _deployStrategy(bytecode);
    }
}
