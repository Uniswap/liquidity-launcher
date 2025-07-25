// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IDistributionContract} from "./IDistributionContract.sol";

/// @notice Interface for the BasicMigrator contract
interface IBasicMigrator is IDistributionContract {
    function migrate() external;

    function setInitialPrice(address currency, uint256 amount, uint256 price) external payable;
}
