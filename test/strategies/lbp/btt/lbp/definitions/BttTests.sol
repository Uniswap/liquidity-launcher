// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ConstructorTest} from "./Constructor.sol";
import {OnTokensReceivedTest} from "./onTokensReceived.sol";
import {SweepTokenTest} from "./sweepToken.sol";

/// @title BttTests
/// @notice All btt tests
abstract contract BttTests is ConstructorTest, OnTokensReceivedTest, SweepTokenTest {}
