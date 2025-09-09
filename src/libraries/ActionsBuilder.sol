// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

/// @title ActionsBuilder
/// @notice Library for building position actions and parameters
library ActionsBuilder {
    error InvalidActionsLength(uint256 invalidLength);

    /// @notice Number of actions needed for a standalone full-range position
    uint256 public constant ACTIONS_LENGTH = 5;

    /// @notice Builds full range position actions
    function buildFullRangeActions() internal pure returns (bytes memory) {
        return abi.encodePacked(
            uint8(Actions.SETTLE),
            uint8(Actions.SETTLE),
            uint8(Actions.MINT_POSITION_FROM_DELTAS),
            uint8(Actions.CLEAR_OR_TAKE),
            uint8(Actions.CLEAR_OR_TAKE)
        );
    }

    /// @notice Builds one-sided position actions to append
    function buildOneSidedActions(bytes memory existingActions) internal pure returns (bytes memory) {
        if (existingActions.length != ACTIONS_LENGTH) {
            revert InvalidActionsLength(existingActions.length);
        }

        return abi.encodePacked(
            existingActions,
            uint8(Actions.SETTLE),
            uint8(Actions.MINT_POSITION_FROM_DELTAS),
            uint8(Actions.CLEAR_OR_TAKE)
        );
    }
}
