// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

struct Plan {
    bytes actions;
    bytes[] params;
}

using Planner for Plan global;

library Planner {
    function init() internal pure returns (Plan memory plan) {
        return Plan({actions: bytes(""), params: new bytes[](0)});
    }

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

    function encode(Plan memory plan) internal pure returns (bytes memory) {
        return abi.encode(plan.actions, plan.params);
    }
}
