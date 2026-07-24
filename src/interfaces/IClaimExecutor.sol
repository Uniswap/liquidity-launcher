// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title IClaimExecutor
/// @notice Callback interface for contracts that process amounts claimed from a v4 LP position recipient
/// @dev Executors MUST report support for this interface via ERC165 `supportsInterface` to receive
///      the callback; callers that do not are paid out without one.
interface IClaimExecutor is IERC165 {
    /// @notice Called by a position recipient after it has transferred the claimed amounts to the executor
    /// @param poolKey The pool key for the position
    /// @param tokenId The token ID of the position
    /// @param currency0Received The amount of currency0 transferred to the executor
    /// @param currency1Received The amount of currency1 transferred to the executor
    function onClaimed(PoolKey memory poolKey, uint256 tokenId, uint256 currency0Received, uint256 currency1Received)
        external;
}
