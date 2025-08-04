// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IDistributionStrategy} from "../interfaces/IDistributionStrategy.sol";
import {IDistributionContract} from "../interfaces/IDistributionContract.sol";
import {LBPStrategyBasic} from "../distributionContracts/LBPStrategyBasic.sol";
import {MigratorParameters} from "../types/MigratorParams.sol";

/// @title LBPStrategyBasicFactory
/// @notice Factory for the LBPStrategyBasic contract
contract LBPStrategyBasicFactory is IDistributionStrategy {
    /// @inheritdoc IDistributionStrategy
    function initializeDistribution(address token, uint256 totalSupply, bytes calldata configData)
        external
        returns (IDistributionContract lbp)
    {
        // decode configData
        (MigratorParameters memory parameters, bytes memory auctionParamsEncoded) =
            abi.decode(configData, (MigratorParameters, bytes));
        bytes32 salt = keccak256(configData);
        lbp = IDistributionContract(address(new LBPStrategyBasic{salt: salt}(token, totalSupply, configData)));
    }
}
