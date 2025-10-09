// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LBPStrategyBasic} from "./LBPStrategyBasic.sol";
import {IVirtualERC20} from "../interfaces/external/VirtualERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Math} from "@openzeppelin-latest/contracts/utils/math/Math.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {BasePositionParams, FullRangeParams, OneSidedParams} from "../types/PositionTypes.sol";
import {ParamsBuilder} from "../libraries/ParamsBuilder.sol";
import {TokenPricing} from "../libraries/TokenPricing.sol";
import {MigratorParameters} from "../types/MigratorParams.sol";
import {Auction} from "twap-auction/src/Auction.sol";
import {HookBasic} from "../utils/HookBasic.sol";
import {MigrationData} from "../types/MigrationData.sol";

/// @title VirtualLBPStrategyBasic
/// @notice Strategy for distributing virtual tokens to a v4 pool
/// Virtual tokens are ERC20 tokens that wrap an underlying token. 
contract VirtualLBPStrategyBasic is LBPStrategyBasic {
    using TokenPricing for *;

    event MigrationApproved();
    event GovernanceSet(address govnerance);

    error MigrationNotApproved();
    error NotGovernance();

    /// @notice The address of Aztec Governance
    address immutable GOVERNANCE;
    
    /// @notice The address of the underlying token that is being distributed - used in the migrated pool
    address immutable UNDERLYING_TOKEN;

    /// @notice Whether migration is approved by Governance
    bool public isMigrationApproved = false;

    constructor(
        address _token,
        uint128 _totalSupply,
        MigratorParameters memory migratorParams,
        bytes memory auctionParams,
        IPositionManager _positionManager,
        IPoolManager _poolManager,
        address _governance
    ) 
    // Underlying strategy
    LBPStrategyBasic(_token, _totalSupply, migratorParams, auctionParams, _positionManager, _poolManager) 
    {
      UNDERLYING_TOKEN = IVirtualERC20(_token).UNDERLYING_TOKEN_ADDRESS();
      GOVERNANCE = _governance;
      emit GovernanceSet(_governance);
    }

    function approveMigration() external {
      if (msg.sender != GOVERNANCE) revert NotGovernance();
      isMigrationApproved = true;
      emit MigrationApproved();
    }

    function _validateMigration() internal override(LBPStrategyBasic) view {
        if (block.number < migrationBlock) {
            revert MigrationNotAllowed(migrationBlock, block.number);
        }

        if (!isMigrationApproved) revert MigrationNotApproved();

        uint256 currencyAmount = auction.currencyRaised();

        if (Currency.wrap(currency).balanceOf(address(this)) < currencyAmount) {
            revert InsufficientCurrency(currencyAmount, Currency.wrap(currency).balanceOf(address(this)));
        }
    }

    function getPoolToken() internal override view returns (address) {
        return UNDERLYING_TOKEN;
    }

}
