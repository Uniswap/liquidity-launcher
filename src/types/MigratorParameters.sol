// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title MigratorParameters
/// @notice Parameters for the LBPStrategyBasic contract
struct MigratorParameters {
    uint64 migrationBlock; // block number when the migration can begin
    address currency; // the currency that the token will be paired with in the v4 pool (currency that the auction raised funds in)
    uint24 poolLPFee; // the LP fee that the v4 pool will use
    int24 poolTickSpacing; // the tick spacing that the v4 pool will use
    uint24 tokenSplitToAuction; // the percentage of the total supply of the token that will be sent to the auction, expressed in mps (1e7 = 100%)
    address auctionFactory; // the Auction factory that will be used to create the auction
    address positionRecipient; // the address that will receive the position
    uint64 sweepBlock; // the block number when the operator can sweep currency and tokens from the pool
    address operator; // the address that is able to sweep currency and tokens from the pool
    bool createOneSidedTokenPosition; // whether to try to create a one-sided position in the token after the full range position or not
    bool createOneSidedCurrencyPosition; // whether to try to create a one-sided position in the currency after the full range position or not
}
