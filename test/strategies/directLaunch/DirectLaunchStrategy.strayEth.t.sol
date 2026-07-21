// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DirectLaunchTestBase} from "./base/DirectLaunchTestBase.sol";
import {DirectLaunchStrategy} from "../../../src/strategies/DirectLaunchStrategy.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Regression test for the stray-ETH griefing DoS on DirectLaunchStrategy.
/// The launch plan settles currency0 (ETH) with CONTRACT_BALANCE and TAKE_PAIRs any credit to the
/// strategy (MSG_SENDER). The single-sided token launch supplies no ETH, but an attacker can force ETH
/// onto the shared PositionManager (e.g. via SELFDESTRUCT); that settle then routes it to the strategy.
/// Without a payable receiver the native transfer reverts and bricks every launch. The added receive()
/// lets the launch complete; the stray wei is accepted and left inert on the strategy.
/// @dev Overrides setUp with a tick aligned to the current TICK_SPACING (the base fixture's INITIAL_TICK
///      is not aligned on dev), so this is independent of that separate fixture issue.
contract DirectLaunchStrategyStrayEthTest is DirectLaunchTestBase {
    int24 internal constant ALIGNED_INITIAL_TICK = 121_980; // 60-aligned; the base's 122_000 is not

    function setUp() public override {
        deployCodeTo("lib/v4-core/src/PoolManager.sol:PoolManager", abi.encode(address(this)), address(POOL_MANAGER));
        deployCodeTo(
            "lib/v4-periphery/src/PositionManager.sol:PositionManager",
            abi.encode(POOL_MANAGER, address(0), uint256(0), address(0), address(0)),
            address(POSITION_MANAGER)
        );
        strategy = new DirectLaunchStrategy(launcher, POSITION_MANAGER, POOL_MANAGER, ALIGNED_INITIAL_TICK);
        vm.deal(address(this), 100_000 ether);
    }

    /// @notice Control: a normal launch (no stray ETH on the PositionManager) succeeds.
    function test_launch_succeedsWithoutStrayEth() public {
        assertEq(address(POSITION_MANAGER).balance, 0, "precondition: PM has no ETH");
        MockERC20 token = _deployToken(TOTAL_SUPPLY);
        _initialize(IERC20(address(token)), TOTAL_SUPPLY, bytes(""));
        assertEq(address(strategy).balance, 0);
    }

    /// @notice The fix: a launch succeeds even when the PositionManager already holds stray ETH.
    ///         Before receive() was added, this reverted at the currency0 TAKE_PAIR (NativeTransferFailed).
    function test_launch_succeedsWithStrayEthOnPositionManager() public {
        vm.deal(address(POSITION_MANAGER), 1); // models ETH force-sent via SELFDESTRUCT
        MockERC20 token = _deployToken(TOTAL_SUPPLY);
        _initialize(IERC20(address(token)), TOTAL_SUPPLY, bytes("")); // no revert

        // The stray wei is swept through the plan into the strategy and left inert (never spent).
        assertEq(address(strategy).balance, 1, "stray ETH accepted by strategy");
        assertEq(token.balanceOf(address(strategy)), 0, "token dust burned as usual");
    }
}
