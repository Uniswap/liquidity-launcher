// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IDistributionContract} from "./IDistributionContract.sol";

struct LBPInitializationParams {
    uint256 initialPriceX96; // the price discovered by the contract
    uint256 tokensSold; // the number of tokens sold by the contract
    uint256 currencyRaised; // the amount of currency raised by the contract
}

/// @title ILBPInitializer
/// @notice Generic interface for contracts used for initializing an LBP strategy
interface ILBPInitializer is IDistributionContract {
    /// @notice Returns the LBP initialization parameters as determined by the implementing contract
    /// @dev The implementing contract MUST ensure that these values are correct at the time of calling
    /// @return params The LBP initialization parameters
    function lbpInitializationParams() external view returns (LBPInitializationParams memory params);
}
