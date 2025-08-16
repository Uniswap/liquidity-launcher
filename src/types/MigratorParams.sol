// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

/// @title MigratorParameters
/// @notice Parameters for the LBPStrategyBasic contract
struct MigratorParameters {
    uint64 migrationBlock; // block number when the migration can begin
    address currency; // the currency that the token will be paired with in the v4 pool (currency that the auction raised funds in)
    uint24 fee; // the LP fee that the v4 pool will use
    address positionManager; // the position manager that will be used to mint the position
    int24 tickSpacing; // the tick spacing that the v4 pool will use
    address poolManager; // the pool manager that will be used to create the v4 pool
    uint16 tokenSplitToAuction; // the percentage of the total supply of the token that will be sent to the auction
    address auctionFactory; // the IDistributionStrategy factory that will be used to create the auction
    address positionRecipient; // the address that will receive the position
}
