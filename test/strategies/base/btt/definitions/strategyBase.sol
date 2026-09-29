// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {StrategyBase} from "../../../../../src/strategies/base/StrategyBase.sol";
import {MockV4FeeAdapter} from "../../../../mocks/MockV4FeeAdapter.sol";

contract MockPoolManagerWithFeeController {
    address public protocolFeeController;

    function setProtocolFeeController(address controller) external {
        protocolFeeController = controller;
    }
}

contract StrategyBaseHarness is StrategyBase {
    constructor(IPoolManager _poolManager) StrategyBase(_poolManager) {}

    function handleFeeUpdate(PoolKey memory key) external returns (bool success, bytes memory data) {
        return _handleFeeUpdate(key);
    }
}

/// @title StrategyBaseTest
/// @notice BTT tests for StrategyBase._handleFeeUpdate
///
/// _handleFeeUpdate
/// ├── when the protocol fee controller is unset
/// │   └── it returns false and empty data without calling the fee adapter
/// └── when the protocol fee controller is set
///     ├── when triggerFeeUpdate succeeds
///     │   └── it returns true, empty data, and forwards the pool key
///     └── when triggerFeeUpdate reverts
///         └── it returns false and the revert data
contract StrategyBaseTest is Test {
    MockPoolManagerWithFeeController public mockPoolManager;
    MockV4FeeAdapter public adapter;
    StrategyBaseHarness public harness;

    function setUp() public {
        mockPoolManager = new MockPoolManagerWithFeeController();
        adapter = new MockV4FeeAdapter();
        harness = new StrategyBaseHarness(IPoolManager(address(mockPoolManager)));
    }

    function test_WhenProtocolFeeControllerIsUnset_returnsFalseWithoutCallingFeeAdapter(PoolKey memory key) public {
        // it returns false and empty data without calling the fee adapter
        (bool success, bytes memory data) = harness.handleFeeUpdate(key);

        assertFalse(success);
        assertEq(data.length, 0);
        assertEq(adapter.callCount(), 0);
    }

    function test_WhenTriggerFeeUpdateSucceeds_returnsTrueAndForwardsPoolKey(PoolKey memory key) public {
        // it returns true, empty data, and forwards the pool key
        mockPoolManager.setProtocolFeeController(address(adapter));

        (bool success, bytes memory data) = harness.handleFeeUpdate(key);

        assertTrue(success);
        assertEq(data.length, 0);
        assertEq(adapter.callCount(), 1);
        assertEq(adapter.lastKeyHash(), keccak256(abi.encode(key)));
    }

    function test_WhenTriggerFeeUpdateReverts_returnsFalseAndRevertData(PoolKey memory key) public {
        // it returns false and the revert data
        adapter.setShouldRevert(true);
        mockPoolManager.setProtocolFeeController(address(adapter));

        (bool success, bytes memory data) = harness.handleFeeUpdate(key);

        assertFalse(success);
        assertEq(data, abi.encodeWithSelector(MockV4FeeAdapter.TriggerFeeUpdateFailed.selector));
        assertEq(adapter.callCount(), 0);
    }
}
