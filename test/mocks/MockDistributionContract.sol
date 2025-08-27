// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IDistributionContract} from "../../src/interfaces/IDistributionContract.sol";

contract MockDistributionContract is IDistributionContract {
    function onTokensReceived() external {}
}
