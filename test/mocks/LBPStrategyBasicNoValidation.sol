// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {LBPStrategyBasic} from "../../src/distributionContracts/LBPStrategyBasic.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {MigratorParameters} from "../../src/types/MigratorParams.sol";

/// @title LBPStrategyBasicNoValidation
/// @notice Test version of LBPStrategyBasic that skips hook address validation
contract LBPStrategyBasicNoValidation is LBPStrategyBasic {
    constructor(
        address _tokenAddress,
        uint256 _totalSupply,
        MigratorParameters memory migratorParams,
        bytes memory auctionParams
    ) LBPStrategyBasic(_tokenAddress, _totalSupply, migratorParams, auctionParams) {}

    /// @dev Override to skip hook address validation during testing
    function validateHookAddress(BaseHook) internal pure override {}
}
