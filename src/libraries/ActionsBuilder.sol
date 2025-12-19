// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ParamsBuilder} from "./ParamsBuilder.sol";

/// @title ActionsBuilder
/// @notice Library for building position actions and parameters
library ActionsBuilder {
    /// @notice Initializes empty actions
    function init() internal pure returns (bytes memory) {
        return bytes("");
    }

    /// @notice Adds mint action to existing actions
    function addMint(bytes memory actions) internal pure returns (bytes memory) {
        return abi.encodePacked(actions, uint8(Actions.MINT_POSITION));
    }

    /// @notice Adds settle action to existing actions
    function addSettle(bytes memory actions) internal pure returns (bytes memory) {
        return abi.encodePacked(actions, uint8(Actions.SETTLE));
    }

    /// @notice Adds take pair action to existing actions
    function addTakePair(bytes memory actions) internal pure returns (bytes memory) {
        return abi.encodePacked(actions, uint8(Actions.TAKE_PAIR));
    }
}
