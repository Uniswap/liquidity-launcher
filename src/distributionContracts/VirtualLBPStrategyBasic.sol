// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LBPStrategyBasic} from "./LBPStrategyBasic.sol";
import {IVirtualERC20} from "../interfaces/external/IVirtualERC20.sol";

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
import {MigratorParameters} from "../types/MigratorParameters.sol";
import {ContinuousClearingAuction} from "continuous-clearing-auction/src/ContinuousClearingAuction.sol";
import {HookBasic} from "../utils/HookBasic.sol";
import {MigrationData} from "../types/MigrationData.sol";

/// @title VirtualLBPStrategyBasic
/// @notice Strategy for distributing virtual tokens to a v4 pool
/// Virtual tokens are ERC20 tokens that wrap an underlying token.
contract VirtualLBPStrategyBasic is LBPStrategyBasic {
    /// @notice Emitted when migration is approved by the governance address
    event MigrationApproved();
    /// @notice Emitted when the governance address is set
    /// @param governance The address of the governance address
    event GovernanceSet(address governance);

    /// @notice Error thrown when migration is not approved yet by the governance address
    error MigrationNotApproved();
    /// @notice Error thrown when the caller is not the governance address
    error NotGovernance();

    /// @notice The address of Aztec Governance
    address public immutable GOVERNANCE;

    /// @notice The address of the underlying token that is being distributed - used in the migrated pool
    address public immutable UNDERLYING_TOKEN;

    /// @notice Whether migration is approved by Governance
    bool public isMigrationApproved = false;

    constructor(
        address _token,
        uint128 _totalSupply,
        MigratorParameters memory _migratorParams,
        bytes memory _auctionParams,
        IPositionManager _positionManager,
        IPoolManager _poolManager,
        address _governance
    )
        // Underlying strategy
        LBPStrategyBasic(_token, _totalSupply, _migratorParams, _auctionParams, _positionManager, _poolManager)
    {
        UNDERLYING_TOKEN = IVirtualERC20(_token).UNDERLYING_TOKEN_ADDRESS();
        GOVERNANCE = _governance;
        emit GovernanceSet(_governance);
    }

    /// @notice Approves migration of the virtual token to the v4 pool
    /// @dev Only callable by the governance address
    function approveMigration() external {
        if (msg.sender != GOVERNANCE) revert NotGovernance();
        isMigrationApproved = true;
        emit MigrationApproved();
    }

    /// @notice Validates that migration is approved and calls the parent _validateMigration function
    /// @dev Reverts if migration is not approved
    function _validateMigration() internal override(LBPStrategyBasic) {
        if (!isMigrationApproved) revert MigrationNotApproved();
        super._validateMigration();
    }

    /// @notice Returns the address of the underlying token
    function getPoolToken() internal view override returns (address) {
        return UNDERLYING_TOKEN;
    }
}
