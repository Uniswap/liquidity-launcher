// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Lifecycle of one bonding-curve pool.
/// @dev Ordered so that every legal transition is exactly `+1`. Storage default is `Unconfigured`.
///      Unconfigured → Seeding → Active → Graduating → Graduated. There are no other legal edges.
enum CurvePhase {
    Unconfigured,
    Seeding,
    Active,
    Graduating,
    Graduated
}

using {advanceTo} for CurvePhase global;

/// @notice Thrown when a phase transition is not the single legal forward edge
error IllegalPhaseTransition(CurvePhase from, CurvePhase to);

/// @notice Advances `from` to `to`, reverting unless `to` is the immediate successor of `from`.
/// @dev Centralizes the entire state machine in one place: the caller writes the returned value back
///      to storage. Because the enum is ordered, "legal" is simply `to == from + 1`, which forbids
///      skips (e.g. Active → Graduated), backwards moves, and self-loops.
function advanceTo(CurvePhase from, CurvePhase to) pure returns (CurvePhase) {
    if (uint8(to) != uint8(from) + 1) revert IllegalPhaseTransition(from, to);
    return to;
}
