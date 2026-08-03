// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IMulticall} from "./interfaces/IMulticall.sol";

/// @title Multicall
/// @notice Enables calling multiple methods in a single call to the contract
abstract contract Multicall is IMulticall {
    /// @inheritdoc IMulticall
    /// @dev Payable so a batch can carry native for `callWithValue`.
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory results) {
        results = new bytes[](data.length);
        for (uint256 i = 0; i < data.length; i++) {
            (bool success, bytes memory result) = address(this).delegatecall(data[i]);

            if (!success) {
                // bubble up the revert reason
                assembly {
                    revert(add(result, 0x20), mload(result))
                }
            }

            results[i] = result;
        }

        // Native must not be left behind, so a batch either forwards all of it or sweeps the remainder.
        if (address(this).balance != 0) revert NativeNotSwept(address(this).balance);
    }

    /// @inheritdoc IMulticall
    function callWithValue(address target, uint256 value, bytes calldata data)
        external
        payable
        returns (bytes memory returnData)
    {
        (bool success, bytes memory result) = target.call{value: value}(data);
        if (!success) {
            assembly {
                revert(add(result, 0x20), mload(result))
            }
        }
        return result;
    }
}
