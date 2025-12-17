// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base, FuzzConstructorParameters} from "../Base.sol";
import {FullRangeLBPStrategy} from "src/strategies/lbp/FullRangeLBPStrategy.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {MigratorParameters} from "src/types/MigratorParameters.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ILBPStrategyBase} from "src/interfaces/ILBPStrategyBase.sol";

/// @title BttBase
/// @notice Base contract for testing the FullRangeLBPStrategy contract
abstract contract BttBase is Base {
    /// @inheritdoc Base
    function _getHookAddress() internal pure override returns (address) {
        return
            address(
                uint160(uint256(type(uint160).max) & CLEAR_ALL_HOOK_PERMISSIONS_MASK | Hooks.BEFORE_INITIALIZE_FLAG)
            );
    }

    /// @inheritdoc Base
    function _contractName() internal pure override returns (string memory) {
        return "FullRangeLBPStrategy";
    }
}
