// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IDistributor} from "../../src/interfaces/IDistributor.sol";

contract MockDistributor is IDistributor {
    function onTokensReceived() external {}
}
