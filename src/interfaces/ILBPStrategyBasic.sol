// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IDistributionContract} from "./IDistributionContract.sol";

/// @notice Interface for the BasicMigrator contract
interface ILBPStrategyBasic is IDistributionContract {
    error MigrationNotAllowed();
    error InvalidSender();

    function migrate() external;

    function setInitialPrice(uint160 _sqrtPriceX96, uint256 _tokenAmount) external payable;
}
