// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title IClaimExecutor
/// @notice Callback interface for contracts that process amounts claimed from a v4 LP position recipient
/// @dev Only recipients that require a callback (see `ExecutorCallbackPositionRecipient`) invoke this, and
///      they invoke it unconditionally: the caller of `claim` on such a recipient MUST implement `onClaimed`.
///      Recipients that do not need a callback (e.g. `BeneficiaryVault`) never call it.
interface IClaimExecutor {
    /// @notice Called by a position recipient after it has transferred the claimed amounts to the executor
    /// @param poolKey The pool key for the position
    /// @param tokenId The token ID of the position
    /// @param currency0Received The amount of currency0 transferred to the executor
    /// @param currency1Received The amount of currency1 transferred to the executor
    function onClaimed(PoolKey memory poolKey, uint256 tokenId, uint256 currency0Received, uint256 currency1Received)
        external;
}
