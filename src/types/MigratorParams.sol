// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

/// @title MigratorParameters
/// @notice Parameters for the LBPStrategyBasic contract
struct MigratorParameters {
    address currency;
    uint24 fee;
    address positionManager;
    int24 tickSpacing;
    address poolManager;
    uint16 tokenSplit;
    address auctionFactory;
    address positionRecipient;
    uint64 migrationBlock;
}
