// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IDistributionContract} from "./IDistributionContract.sol";

/// @title IMerkleClaim
/// @notice Interface for the MerkleClaim contract
interface IMerkleClaim is IDistributionContract {
    /// @notice Emitted when tokens are swept by the owner after endTime
    /// @param owner The address that swept the tokens
    /// @param amount The amount of tokens swept
    event TokensSwept(address indexed owner, uint256 amount);

    /// @notice Sweep remaining tokens to the owner after endTime
    /// @dev Only callable by owner and only after endTime has passed
    function sweep() external;
}
