// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IAuction} from "twap-auction/src/interfaces/IAuction.sol";

/// @notice Temporary mock interface extending IAuction with missing methods
/// @dev This should be removed once the latest IAuction interface is pulled
interface IMockAuction is IAuction {
    /// @notice Returns the end block of the auction
    function endBlock() external view returns (uint64);

    /// @notice Sweeps currency from the auction to the caller
    function sweepCurrency() external;
}
