// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ContinuousClearingAuctionFactory} from "continuous-clearing-auction/src/ContinuousClearingAuctionFactory.sol";

contract DeployContinuousClearingAuctionFactoryMainnetScript is Script {
    function run() public {
        vm.startBroadcast();
        ContinuousClearingAuctionFactory continuousClearingAuctionFactory =
            new ContinuousClearingAuctionFactory{salt: bytes32(0)}();

        console.log("ContinuousClearingAuctionFactory deployed to:", address(continuousClearingAuctionFactory));
        vm.stopBroadcast();
    }
}
