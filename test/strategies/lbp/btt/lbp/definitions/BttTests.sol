// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ConstructorTest} from "./constructor.sol";
import {OnTokensReceivedTest} from "./onTokensReceived.sol";
import {SweepTokenTest} from "./sweepToken.sol";
import {SweepCurrencyTest} from "./sweepCurrency.sol";
import {MigrateTests} from "./migrate/MigrateTests.sol";

/// @title BttTests
/// @notice All btt tests
abstract contract BttTests is ConstructorTest, OnTokensReceivedTest, SweepTokenTest, SweepCurrencyTest, MigrateTests {}
