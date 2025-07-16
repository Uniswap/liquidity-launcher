// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IDistributionStrategy} from "./IDistributionStrategy.sol";

/// @title IMerkleFactory
/// @notice Interface for merkle distribution factory contracts.
interface IMerkleFactory is IDistributionStrategy {
    /// @notice Custom errors for merkle factory functionality
    error ZeroAddress();
    error InvalidConfig();
}