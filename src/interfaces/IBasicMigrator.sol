// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IDistributionContract} from "./IDistributionContract.sol";

/// @notice Interface for the BasicMigrator contract
interface IBasicMigrator is IDistributionContract {
    function migrate() external;

    function setInitialPrice(address currency, uint256 amount) external payable;

    function onTokensReceived(address _token, uint256 _amount) external view;
}
