// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IDistributionContract} from "../../src/interfaces/IDistributionContract.sol";
import {console2} from "forge-std/console2.sol";

contract MockDistributionContract is IDistributionContract {
    function onTokensReceived() external {
        console2.log("i am here");
    }
}
