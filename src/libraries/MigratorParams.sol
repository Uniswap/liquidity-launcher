// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {ILBPStrategy} from "../interfaces/ILBPStrategy.sol";
import {PositionPlanner} from "./PositionPlanner.sol";
import {PositionDefinition} from "../types/PositionPlannerTypes.sol";

/// @notice Migration parameters for an initializer
struct MigratorParameters {
    uint64 migrationBlock; // block number when the migration can begin
    uint24 poolLPFee; // the LP fee that the v4 pool will use
    int24 poolTickSpacing; // the tick spacing that the v4 pool will use
    uint128 supplyForLP; // amount of the token used for LP creation
    address fundsRecipient; // the address that will receive the funds from the auction
    address lpPositionRecipient; // the address that will receive the created LP position
    address hook; // the hook that will be used to initialize the pool. Any nonzero hook MUST inherit InitializerHook.
    bytes positionDefinitions; // abi-encoded PositionDefinition[] describing the weighted LP plan
    bytes lpAllocationSchedule; // abi-encoded LiquidityAllocationBracket[]
}

/// @notice A single bracket in the LP allocation schedule. Each bracket pairs a lower threshold
/// (in cumulative currency raised) with the rate of currency allocated to the LP within that bracket.
/// @dev Brackets MUST be supplied in strictly ascending order by lowerThreshold; the contract reverts
/// if not (no on-chain sort is performed). The first bracket's lowerThreshold MUST be 0. Each bracket's
/// rate applies from its lowerThreshold up to the next bracket's lowerThreshold (or infinity for the
/// last bracket).
struct LiquidityAllocationBracket {
    uint256 lowerThreshold; // lower bound of this bracket in cumulative currency amount (first bracket must be 0)
    uint24 rate; // % of currency allocated to LP within this bracket, in mps (1e7 = 100%)
}

/// @title MigratorParams
/// @notice Validation helpers for MigratorParameters, including the embedded LP allocation schedule
/// and the position-planner definitions.
library MigratorParams {
    /// @notice The maximum bracket rate (100% in mps)
    uint24 internal constant MAX_BRACKET_RATE = 1e7;
    /// @notice The maximum number of brackets in the LP allocation schedule
    uint256 internal constant MAX_BRACKETS = 3;

    /// @notice Error thrown when the LP allocation schedule has an invalid number of brackets (empty or exceeds max)
    /// @param count The invalid bracket count
    error InvalidBracketCount(uint256 count);

    /// @notice Error thrown when a bracket rate is greater than MAX_BRACKET_RATE
    /// @param rate The invalid bracket rate
    error InvalidBracketRate(uint24 rate);

    /// @notice Error thrown when a bracket lowerThreshold is not strictly ascending vs the previous bracket
    /// @param lowerThreshold The invalid bracket lowerThreshold
    error InvalidBracketThreshold(uint256 lowerThreshold);

    /// @notice Validates the full migrator parameters struct: scalar fields, supplyForLP cap,
    /// position plan definitions, and the embedded LP allocation schedule. Reverts on any invalidity.
    /// @param p The migrator parameters to validate
    function validate(MigratorParameters memory p) internal pure {
        // tick spacing validation (cannot be greater than the v4 max tick spacing or less than the v4 min tick spacing)
        if (p.poolTickSpacing > TickMath.MAX_TICK_SPACING || p.poolTickSpacing < TickMath.MIN_TICK_SPACING) {
            revert ILBPStrategy.InvalidTickSpacing(
                p.poolTickSpacing, TickMath.MIN_TICK_SPACING, TickMath.MAX_TICK_SPACING
            );
        }
        // fee validation (cannot be greater than the v4 max fee)
        if (p.poolLPFee > LPFeeLibrary.MAX_LP_FEE) {
            revert ILBPStrategy.InvalidFee(p.poolLPFee, LPFeeLibrary.MAX_LP_FEE);
        }
        // position recipient validation (cannot be zero address, address(1), or address(2) which are reserved addresses on the position manager)
        if (
            p.lpPositionRecipient == address(0) || p.lpPositionRecipient == ActionConstants.MSG_SENDER
                || p.lpPositionRecipient == ActionConstants.ADDRESS_THIS
        ) {
            revert ILBPStrategy.InvalidPositionRecipient(p.lpPositionRecipient);
        }
        // supplyForLP must fit in int128 — v4's PoolManager._accountDelta uses int128 for token deltas,
        // so values above int128.max would revert with SafeCastOverflow at migration time.
        if (p.supplyForLP > uint128(type(int128).max)) {
            revert ILBPStrategy.InvalidSupplyForLp(p.supplyForLP, uint128(type(int128).max));
        }
        // Position plan validation (non-empty, weights sum to MPS)
        PositionPlanner.validate(abi.decode(p.positionDefinitions, (PositionDefinition[])));
        // LP allocation schedule validation (1..MAX_BRACKETS brackets, ascending, rates in [0, MAX_BRACKET_RATE])
        _validateLpAllocationSchedule(p.lpAllocationSchedule);
    }

    /// @notice Validates an abi-encoded LP allocation schedule
    /// @dev The schedule is an abi-encoded LiquidityAllocationBracket[]. It must contain 1 to MAX_BRACKETS brackets,
    /// with the first bracket's lowerThreshold = 0, all rates in [0, MAX_BRACKET_RATE], and strictly ascending
    /// lowerThresholds.
    /// @param _schedule The abi-encoded LP allocation schedule
    function _validateLpAllocationSchedule(bytes memory _schedule) private pure {
        LiquidityAllocationBracket[] memory brackets = abi.decode(_schedule, (LiquidityAllocationBracket[]));
        uint256 count = brackets.length;
        if (count == 0 || count > MAX_BRACKETS) revert InvalidBracketCount(count);

        uint256 prevLower;
        for (uint256 i = 0; i < count; i++) {
            uint256 lowerThreshold = brackets[i].lowerThreshold;
            uint24 rate = brackets[i].rate;
            if (rate > MAX_BRACKET_RATE) revert InvalidBracketRate(rate);
            if (i == 0 && lowerThreshold != 0) revert InvalidBracketThreshold(lowerThreshold);
            if (i > 0 && lowerThreshold <= prevLower) revert InvalidBracketThreshold(lowerThreshold);
            prevLower = lowerThreshold;
        }
    }
}
