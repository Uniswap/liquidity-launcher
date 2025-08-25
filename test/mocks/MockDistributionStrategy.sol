// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IDistributionStrategy} from "../../src/interfaces/IDistributionStrategy.sol";

contract MockDistributionStrategy is IDistributionStrategy {
    function initializeDistribution(address, uint128, bytes calldata, bytes32) external {}

    function getAddressesAndAmounts(address, uint128, bytes calldata, bytes32)
        external
        pure
        override
        returns (address[2] memory, uint128[2] memory)
    {
        return ([address(0), address(0)], [uint128(0), uint128(0)]);
    }
}
