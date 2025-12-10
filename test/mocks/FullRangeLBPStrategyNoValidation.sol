// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FullRangeLBPStrategy} from "../../src/distributionContracts/FullRangeLBPStrategy.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {MigratorParameters} from "../../src/types/MigratorParameters.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/// @title FullRangeLBPStrategyNoValidation
/// @notice Test version of FullRangeLBPStrategy that skips hook address validation
contract FullRangeLBPStrategyNoValidation is FullRangeLBPStrategy {
    constructor(
        address _tokenAddress,
        uint128 _totalSupply,
        MigratorParameters memory migratorParams,
        bytes memory auctionParams,
        IPositionManager _positionManager,
        IPoolManager _poolManager
    )
        FullRangeLBPStrategy(_tokenAddress, _totalSupply, migratorParams, auctionParams, _positionManager, _poolManager)
    {}

    /// @dev Override to skip hook address validation during testing
    function validateHookAddress(BaseHook) internal pure override {}

    function setAuctionParameters(bytes memory auctionParams) external {
        auctionParameters = auctionParams;
    }
}
