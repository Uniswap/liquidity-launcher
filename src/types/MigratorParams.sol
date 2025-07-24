// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

/// @notice Parameters for the BasicMigrator contract
struct MigratorParameters {
    address token;
    address currency;
    uint256 totalSupply;
    address positionManager;
    uint24 fee;
    int24 tickSpacing;
    IHooks hooks;
    bytes hookData;
    address positionRecipient;
    uint64 migrationBlock;
}
