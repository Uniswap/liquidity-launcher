// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/// @title Plan
/// @notice Represents a plan of actions to be executed in a pool
struct Plan {
    bytes actions;
    bytes[] params;
}

using Planner for Plan global;

/// @title Planner
/// @notice Library for planning actions to be executed in a pool
library Planner {
    /// @notice Initializes a new plan
    /// @return plan The initialized plan
    function init() internal pure returns (Plan memory plan) {
        return Plan({actions: bytes(""), params: new bytes[](0)});
    }

    /// @notice Adds an action to a plan
    /// @param plan The plan to add the action to
    /// @param action The action to add
    /// @param param The parameter for the action
    /// @return The updated plan
    function add(Plan memory plan, uint256 action, bytes memory param) internal pure returns (Plan memory) {
        bytes memory actions = new bytes(plan.params.length + 1);
        bytes[] memory params = new bytes[](plan.params.length + 1);

        for (uint256 i; i < params.length - 1; i++) {
            // Copy from plan.
            params[i] = plan.params[i];
            actions[i] = plan.actions[i];
        }
        params[params.length - 1] = param;
        actions[params.length - 1] = bytes1(uint8(action));

        plan.actions = actions;
        plan.params = params;

        return plan;
    }

    /// @notice Encodes a plan into a bytes array
    /// @param plan The plan to encode
    /// @return The encoded plan
    function encode(Plan memory plan) internal pure returns (bytes memory) {
        return abi.encode(plan.actions, plan.params);
    }
}
