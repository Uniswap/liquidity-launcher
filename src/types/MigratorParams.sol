// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

/// @title MigratorParameters
/// @notice Parameters for the LBPStrategyBasic contract
struct MigratorParameters {
    uint256 tokenSplit;
    address currency;
    address positionManager;
    address poolManager;
    address auctionFactory;
    address positionRecipient;
    uint64 migrationBlock;
    uint24 fee;
    int24 tickSpacing;
}
