// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDistributionContract} from "../../src/interfaces/IDistributionContract.sol";

contract MockDistributionContract is IDistributionContract {
    function onTokensReceived(address token, uint256 amount) external {}
}
