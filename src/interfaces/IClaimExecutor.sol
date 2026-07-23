// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title IClaimExecutor
/// @notice Callback interface for contracts that process amounts claimed from a v4 LP position recipient
interface IClaimExecutor {
    /// @notice Processes amounts transferred by a position recipient
    /// @param poolKey The pool key for the position
    /// @param tokenId The token ID of the position
    /// @param currency0Received The amount of currency0 transferred to the executor
    /// @param currency1Received The amount of currency1 transferred to the executor
    function callback(PoolKey memory poolKey, uint256 tokenId, uint256 currency0Received, uint256 currency1Received)
        external;
}
