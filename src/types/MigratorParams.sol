// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

/// @notice Parameters for the BasicMigrator contract
struct MigratorParameters {
    uint24 fee;
    int24 tickSpacing;
    IHooks hooks;
    bytes hookData;
    address positionRecipient;
    address tokensRecipient;
    uint64 migrationBlock;
}
