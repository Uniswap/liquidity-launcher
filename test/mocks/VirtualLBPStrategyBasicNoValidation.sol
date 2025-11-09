// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VirtualLBPStrategyBasic} from "../../src/distributionContracts/VirtualLBPStrategyBasic.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {MigratorParameters} from "../../src/types/MigratorParameters.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/// @title VirtualLBPStrategyBasicNoValidation
/// @notice Test version of VirtualLBPStrategyBasic that skips hook address validation
contract VirtualLBPStrategyBasicNoValidation is VirtualLBPStrategyBasic {
    constructor(
        address _tokenAddress,
        uint128 _totalSupply,
        MigratorParameters memory _migratorParams,
        bytes memory _auctionParams,
        IPositionManager _positionManager,
        IPoolManager _poolManager,
        address _governance
    )
        VirtualLBPStrategyBasic(
            _tokenAddress, _totalSupply, _migratorParams, _auctionParams, _positionManager, _poolManager, _governance
        )
    {}

    /// @dev Override to skip hook address validation during testing
    function validateHookAddress(BaseHook) internal pure override {}

    function setAuctionParameters(bytes memory auctionParams) external {
        auctionParameters = auctionParams;
    }
}
