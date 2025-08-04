// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

/// @notice Parameters for the BasicMigrator contract
struct MigratorParameters {
    address currency;
    address positionManager;
    address poolManager;
    uint24 fee;
    int24 tickSpacing;
    address positionRecipient;
    uint64 migrationBlock;
    address auctionFactory;
    uint256 tokenSplit;
}
