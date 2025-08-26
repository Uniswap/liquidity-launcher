// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/// @title MigratorParameters
/// @notice Parameters for the LBPStrategyBasic contract
struct MigratorParameters {
    uint64 migrationBlock; // block number when the migration can begin
    address currency; // the currency that the token will be paired with in the v4 pool (currency that the auction raised funds in)
    uint24 poolLPFee; // the LP fee that the v4 pool will use
    int24 poolTickSpacing; // the tick spacing that the v4 pool will use
    uint16 tokenSplitToAuction; // the percentage of the total supply of the token that will be sent to the auction
    address positionRecipient; // the address that will receive the position
}
