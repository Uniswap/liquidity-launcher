// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BttTests} from "../definitions/BttTests.sol";
import {BttBase} from "../BttBase.sol";

/// @title FullRangeLBPStrategyTest
/// @notice Contract for testing the FullRangeLBPStrategy contract
contract FullRangeLBPStrategyTest is BttTests {
    /// @inheritdoc BttBase
    function _contractName() internal pure override returns (string memory) {
        return "FullRangeLBPStrategy";
    }
}
