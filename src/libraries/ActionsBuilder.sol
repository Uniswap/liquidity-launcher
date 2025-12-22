// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ParamsBuilder} from "./ParamsBuilder.sol";

/// @title ActionsBuilder
/// @notice Library for building position actions and parameters
library ActionsBuilder {
    error InvalidActionsLength(uint256 invalidLength);

    /// @notice Initializes an empty actions byte array
    function init() internal pure returns (bytes memory actions) {
        actions = new bytes(0);
    }

    /// @notice Add mint action to actions byte array
    function addMint(bytes memory actions) internal pure returns (bytes memory) {
        return abi.encodePacked(actions, uint8(Actions.MINT_POSITION));
    }

    /// @notice Add settle action to actions byte array
    function addSettle(bytes memory actions) internal pure returns (bytes memory) {
        return abi.encodePacked(actions, uint8(Actions.SETTLE));
    }

    /// @notice Add take pair action to actions byte array
    function addTakePair(bytes memory actions) internal pure returns (bytes memory) {
        return abi.encodePacked(actions, uint8(Actions.TAKE_PAIR));
    }
}
