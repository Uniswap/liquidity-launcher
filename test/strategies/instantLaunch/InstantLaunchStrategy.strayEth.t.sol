// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {InstantLaunchTestBase} from "./base/InstantLaunchTestBase.sol";
import {InstantLaunchStrategy} from "../../../src/strategies/InstantLaunchStrategy.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Regression test for the stray-ETH griefing DoS on InstantLaunchStrategy.
contract InstantLaunchStrategyStrayEthTest is InstantLaunchTestBase {
    /// @notice Control: a normal launch (no stray ETH on the PositionManager) succeeds.
    function test_launch_succeedsWithoutStrayEth() public {
        assertEq(address(POSITION_MANAGER).balance, 0, "precondition: PM has no ETH");
        MockERC20 token = _deployToken(TOTAL_SUPPLY);
        _initialize(IERC20(address(token)), TOTAL_SUPPLY, _defaultConfig());
        assertEq(address(strategy).balance, 0);
    }

    /// @notice The fix: a launch succeeds even when the PositionManager already holds stray ETH.
    ///         Before receive() was added, this reverted at the currency0 TAKE_PAIR (NativeTransferFailed).
    function test_launch_succeedsWithStrayEthOnPositionManager() public {
        vm.deal(address(POSITION_MANAGER), 1); // models ETH force-sent via SELFDESTRUCT
        MockERC20 token = _deployToken(TOTAL_SUPPLY);
        _initialize(IERC20(address(token)), TOTAL_SUPPLY, _defaultConfig()); // no revert

        // The stray wei is swept through the plan into the strategy and left inert (never spent).
        assertEq(address(strategy).balance, 1, "stray ETH accepted by strategy");
        assertEq(token.balanceOf(address(strategy)), 0, "token dust burned as usual");
    }
}
