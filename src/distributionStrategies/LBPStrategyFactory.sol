// // SPDX-License-Identifier: UNLICENSED
// pragma solidity 0.8.26;

// import {IDistributionStrategy} from "../interfaces/IDistributionStrategy.sol";
// import {IDistributionContract} from "../interfaces/IDistributionContract.sol";

// contract LBPStrategyFactory is IDistributionStrategy {
//     constructor() {}

//     function initializeDistribution(bytes calldata configData) external returns (IDistributionContract lbp) {
//         lbp = IDistributionContract(address(new LBP{salt: keccak256(abi.encode(configData))}(configData)));
//     }
// }
