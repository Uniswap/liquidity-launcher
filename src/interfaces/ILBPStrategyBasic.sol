// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ILBPStrategyBase} from "./ILBPStrategyBase.sol";

/// @title ILBPStrategyBasic
/// @notice Interface for the LBPStrategyBasic contract
interface ILBPStrategyBasic is ILBPStrategyBase {
    /// Getters
    function createOneSidedTokenPosition() external view returns (bool);
    function createOneSidedCurrencyPosition() external view returns (bool);
}
