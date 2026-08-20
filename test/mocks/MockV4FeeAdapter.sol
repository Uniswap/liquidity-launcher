// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IV4FeeAdapter} from "../../src/interfaces/external/IV4FeeAdapter.sol";

/// @notice Recorder for `IV4FeeAdapter.triggerFeeUpdate`, used to assert strategy fee-update calls.
contract MockV4FeeAdapter is IV4FeeAdapter {
    error TriggerFeeUpdateFailed();

    PoolKey public lastKey;
    uint256 public callCount;
    bool public shouldRevert;

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function lastKeyHash() external view returns (bytes32) {
        return keccak256(abi.encode(lastKey));
    }

    function triggerFeeUpdate(PoolKey calldata key) external {
        if (shouldRevert) revert TriggerFeeUpdateFailed();
        lastKey = key;
        callCount++;
    }
}
