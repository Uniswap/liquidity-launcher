// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {ILBPStrategy} from "../interfaces/ILBPStrategy.sol";
import {PositionPlanner} from "./PositionPlanner.sol";
import {PositionDefinition} from "../types/PositionPlannerTypes.sol";
import {IInitializerHook} from "../interfaces/IInitializerHook.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

using StateLibrary for IPoolManager;

/// @notice Migration parameters for an initializer
struct MigratorParameters {
    address token; // launched token; must match function-param `token` AND `initializer.token()` at registration
    address currency; // auction currency; must match `initializer.currency()` at registration
    uint64 migrationBlock; // block number when the migration can begin
    uint128 reservedTokenAmountForLP; // amount of the token reserved for LP creation
    address recipient; // the address that will receive unused currency and unused LP supply after migration
    address positionRecipient; // default recipient of minted LP positions; used for the full-range fallback and any position without an overridePositionRecipient
    PoolParameters poolParameters;
    bytes positionDefinitions; // abi-encoded PositionDefinition[] describing the weighted LP plan
    bytes lpAllocationSchedule; // abi-encoded LiquidityAllocationBracket[]
}

/// @notice Parameters for the v4 pool
struct PoolParameters {
    uint24 fee; // the LP fee that the v4 pool will use
    int24 tickSpacing; // the tick spacing that the v4 pool will use
    address hook;
}

/// @notice A single bracket in the LP allocation schedule. Each bracket pairs a lower threshold
/// (in cumulative currency raised) with the rate of currency allocated to the LP within that bracket.
/// @dev Brackets MUST be supplied in strictly ascending order by lowerThreshold; the contract reverts
/// if not (no on-chain sort is performed). The first bracket's lowerThreshold MUST be 0. Each bracket's
/// rate applies from its lowerThreshold up to the next bracket's lowerThreshold (or infinity for the
/// last bracket).
struct LiquidityAllocationBracket {
    uint128 lowerThreshold; // lower bound of this bracket in cumulative currency amount (first bracket must be 0). cumulative amounts above type(uint128).max are allocated at the last bracket's rate.
    uint24 rate; // % of currency allocated to LP within this bracket, in mps (1e7 = 100%)
}

/// @title MigratorParams
/// @notice Validation helpers for MigratorParameters, including the embedded LP allocation schedule
/// and the position-planner definitions.
library MigratorParams {
    using Hooks for IHooks;

    /// @notice The maximum bracket rate (100% in mps)
    uint24 internal constant MAX_BRACKET_RATE = 1e7;
    /// @notice The maximum number of brackets in the LP allocation schedule
    uint256 internal constant MAX_BRACKETS = 32;

    /// @notice Error thrown when a configured hook does not support IInitializerHook
    /// @param hook The invalid hook address
    error InvalidHook(address hook);

    /// @notice Error thrown when dynamic LP fees are configured without a user-provided hook
    error InvalidDynamicFeeHook();

    /// @notice Error thrown when the launched token and auction currency are the same ERC20
    /// @param token The token address configured as both token and currency
    error InvalidTokenCurrencyPair(address token);

    /// @notice Error thrown when the LP allocation schedule has an invalid number of brackets (empty or exceeds max)
    /// @param count The invalid bracket count
    error InvalidBracketCount(uint256 count);

    /// @notice Error thrown when a bracket rate is greater than MAX_BRACKET_RATE
    /// @param rate The invalid bracket rate
    error InvalidBracketRate(uint24 rate);

    /// @notice Error thrown when a bracket lowerThreshold is not strictly ascending vs the previous bracket
    /// @param lowerThreshold The invalid bracket lowerThreshold
    error InvalidBracketThreshold(uint128 lowerThreshold);

    /// @notice Validates the full migrator parameters struct: scalar fields, reservedTokenAmountForLP cap,
    /// position plan definitions, and the embedded LP allocation schedule. Reverts on any invalidity.
    /// @param p The migrator parameters to validate
    function validate(MigratorParameters memory p) internal pure {
        // Token consistency is checked at registration; reject only concrete same-token ERC20 pairs here.
        if (p.token != address(0) && p.token == p.currency) revert InvalidTokenCurrencyPair(p.token);

        // tick spacing validation (cannot be greater than the v4 max tick spacing or less than the v4 min tick spacing)
        if (
            p.poolParameters.tickSpacing > TickMath.MAX_TICK_SPACING
                || p.poolParameters.tickSpacing < TickMath.MIN_TICK_SPACING
        ) {
            revert ILBPStrategy.InvalidTickSpacing(
                p.poolParameters.tickSpacing, TickMath.MIN_TICK_SPACING, TickMath.MAX_TICK_SPACING
            );
        }
        // fee validation (static fees cannot be greater than the v4 max fee)
        if (p.poolParameters.fee > LPFeeLibrary.MAX_LP_FEE && p.poolParameters.fee != LPFeeLibrary.DYNAMIC_FEE_FLAG) {
            revert ILBPStrategy.InvalidFee(p.poolParameters.fee, LPFeeLibrary.MAX_LP_FEE);
        }
        // Dynamic-fee pools require hook-owned fee logic. The strategy's hookless fallback only gates initialization.
        if (p.poolParameters.fee == LPFeeLibrary.DYNAMIC_FEE_FLAG && p.poolParameters.hook == address(0)) {
            revert InvalidDynamicFeeHook();
        }
        // recipient validation (cannot be zero address). This is the recipient of unallocated
        // currency/token dust after migration.
        if (p.recipient == address(0)) {
            revert ILBPStrategy.InvalidRecipient();
        }
        // positionRecipient is the default recipient of minted LP positions (the full-range fallback and any
        // position without an overridePositionRecipient). It cannot be the zero address, address(1), or
        // address(2), which are reserved addresses on the position manager. Per-position overrides are
        // validated in PositionPlanner.validate.
        if (
            p.positionRecipient == address(0) || p.positionRecipient == ActionConstants.MSG_SENDER
                || p.positionRecipient == ActionConstants.ADDRESS_THIS
        ) {
            revert ILBPStrategy.InvalidPositionRecipient(p.positionRecipient);
        }
        // reservedTokenAmountForLP must be greater than 0 and less than int128.max
        if (p.reservedTokenAmountForLP > uint128(type(int128).max) || p.reservedTokenAmountForLP == 0) {
            revert ILBPStrategy.InvalidReservedTokenAmountForLP();
        }

        PositionPlanner.validate(abi.decode(p.positionDefinitions, (PositionDefinition[])));
        _validateLpAllocationSchedule(p.lpAllocationSchedule);
    }

    /// @notice Validates that the hook set in MigratorParameters correctly implements IInitializerHook and is a
    ///         valid v4 hook for the configured fee that will actually receive the beforeInitialize callback
    /// @dev Reverts if the hook does not implement IInitializerHook, is not authorized to initialize the pool, is not a
    ///      valid v4 hook address for `fee`, or lacks the BEFORE_INITIALIZE_FLAG permission bit, or the target pool is already initialized
    /// @dev Zero hook addresses are not validated but are still checked for pool initialization
    /// @param hook The hook address to validate
    /// @param fee The LP fee configured for the pool the hook will be used with
    /// @param poolId The pool ID to validate
    /// @param poolManager The Uniswap v4 pool manager deployed on the chain
    function validateHook(address hook, uint24 fee, PoolId poolId, IPoolManager poolManager) internal view {
        // Reject an already-initialized pool first, so the check also applies to hookless (zero hook) pools.
        (uint160 existingSqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        if (existingSqrtPriceX96 != 0) {
            revert InvalidHook(hook);
        }
        // zero address hooks don't need to be validated for hook flag bits
        if (hook == address(0)) return;
        if (
            !ERC165Checker.supportsInterface(hook, type(IInitializerHook).interfaceId)
                || IInitializerHook(hook).authorized() != address(this) || !IHooks(hook).isValidHookAddress(fee)
                || !IHooks(hook).hasPermission(Hooks.BEFORE_INITIALIZE_FLAG)
        ) {
            revert InvalidHook(hook);
        }
    }

    /// @notice Validates an abi-encoded LP allocation schedule
    /// @dev The schedule is an abi-encoded LiquidityAllocationBracket[]. It must contain 1 to MAX_BRACKETS brackets,
    /// with the first bracket's lowerThreshold = 0, all rates in (0, MAX_BRACKET_RATE], and strictly ascending
    /// lowerThresholds.
    /// @param _schedule The abi-encoded LP allocation schedule
    function _validateLpAllocationSchedule(bytes memory _schedule) private pure {
        LiquidityAllocationBracket[] memory brackets = abi.decode(_schedule, (LiquidityAllocationBracket[]));
        uint256 count = brackets.length;
        if (count == 0 || count > MAX_BRACKETS) revert InvalidBracketCount(count);

        uint128 prevLower;
        for (uint256 i = 0; i < count; i++) {
            uint128 lowerThreshold = brackets[i].lowerThreshold;
            uint24 rate = brackets[i].rate;
            if (rate == 0 || rate > MAX_BRACKET_RATE) revert InvalidBracketRate(rate);
            if (i == 0 && lowerThreshold != 0) revert InvalidBracketThreshold(lowerThreshold);
            if (i > 0 && lowerThreshold <= prevLower) revert InvalidBracketThreshold(lowerThreshold);
            prevLower = lowerThreshold;
        }
    }
}
