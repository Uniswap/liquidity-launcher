// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MigrationData} from "src/types/MigrationData.sol";

/// @title ILBPStrategyTestExtension
/// @notice Extension for testing LBPStrategy contracts
interface ILBPStrategyTestExtension {
    function prepareMigrationData() external returns (MigrationData memory);
    function createPositionPlan(MigrationData memory data) external returns (bytes memory);
    function getTokenTransferAmount(MigrationData memory data) external view returns (uint128);
    function getCurrencyTransferAmount(MigrationData memory data) external view returns (uint128);
}
