// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BttBase, FuzzConstructorParameters} from "../../BttBase.sol";

/// @title MigrateBttBase
/// @notice Base contract for migrate tests to support arbitrary actions before and after migration
abstract contract MigrateBttBase is BttBase {
    /// @dev Dump parameters and revert data for the current test
    FuzzConstructorParameters internal $parameters;
    bytes internal $revertData;

    /// @notice Modifier to call migrate and perform arbitrary actions before and after migration
    modifier handleMigrate() {
        _;
        _beforeMigrate($parameters);
        if ($revertData.length > 0) {
            vm.expectRevert($revertData);
        }
        lbp.migrate();
        _afterMigrate($parameters);
    }

    /// @notice Override to perform actions before migration
    /// @dev Default to no-op
    function _beforeMigrate(FuzzConstructorParameters memory _parameters) internal virtual {}

    /// @notice Override to perform actions after migration
    /// @dev Default to no-op
    function _afterMigrate(FuzzConstructorParameters memory _parameters) internal virtual {}
}
