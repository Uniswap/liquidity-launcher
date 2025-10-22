// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ParamsBuilder} from "./ParamsBuilder.sol";

/// @title ActionsBuilder
/// @notice Library for building position actions and parameters
library ActionsBuilder {
    error InvalidActionsLength(uint256 invalidLength);

    /// @notice Builds full range position actions
    function buildFullRangeActions() internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE), uint8(Actions.SETTLE));
    }

    /// @notice Builds one-sided position actions to append
    function buildOneSidedActions(bytes memory existingActions) internal pure returns (bytes memory) {
        if (existingActions.length != ParamsBuilder.FULL_RANGE_SIZE - ParamsBuilder.FINAL_TAKE_PAIR_SIZE) {
            revert InvalidActionsLength(existingActions.length);
        }

        return abi.encodePacked(existingActions, uint8(Actions.MINT_POSITION));
    }

    function buildFinalTakePairActions(bytes memory existingActions) internal pure returns (bytes memory) {
        return abi.encodePacked(existingActions, uint8(Actions.TAKE_PAIR));
    }
}
