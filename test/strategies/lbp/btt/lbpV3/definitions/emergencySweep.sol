// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LBPStrategyTestBase} from "../../../base/LBPStrategyTestBase.sol";
import {ILBPStrategy} from "src/interfaces/ILBPStrategy.sol";
import {ILBPInitializer} from "src/interfaces/ILBPInitializer.sol";
import {MockLBPInitializer} from "test/mocks/MockLBPInitializer.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

/// @title EmergencySweepTest
/// @notice BTT tests for LBPStrategy.emergencySweep
///
/// emergencySweep
/// ├── when initializer is unregistered (reserves == 0)
/// │   └── it reverts with AlreadyConsumed
/// ├── when caller != leftoverRecipient
/// │   └── it reverts with UnauthorizedEmergencySweep
/// ├── when block.number < migrationBlock + emergencySweepDelay
/// │   └── it reverts with EmergencySweepNotAllowed
/// ├── when initializer was already migrated
/// │   └── it reverts with AlreadyConsumed
/// ├── when initializer was already emergency-swept
/// │   └── it reverts with AlreadyConsumed
/// └── when called by leftoverRecipient at or past the unlock block on a live initializer
///     ├── it transfers supplyForLP from strategy to leftoverRecipient
///     ├── it zeroes reserves (blocks future migrate and emergencySweep)
///     └── it emits EmergencySwept
contract EmergencySweepTest is LBPStrategyTestBase {
    function test_WhenInitializerIsUnregistered() public {
        ILBPInitializer unregistered = ILBPInitializer(
            address(new MockLBPInitializer(address(1), address(0), 0, address(strategy), address(strategy), 0, 0))
        );

        assertEq(strategy.reserves(unregistered), 0);

        vm.expectRevert(abi.encodeWithSelector(ILBPStrategy.AlreadyConsumed.selector, unregistered));
        strategy.emergencySweep(unregistered);
    }

    function test_WhenCallerIsNotLeftoverRecipient(MigrationFuzzParams memory p, address caller) public {
        (MockLBPInitializer initializer,) = _setupForMigration(p);
        vm.assume(caller != leftoverRecipient);

        // Roll past the unlock block so the "too early" check passes and we reach the auth check.
        vm.roll(p.migrationBlock + strategy.emergencySweepDelay());

        vm.expectRevert(
            abi.encodeWithSelector(ILBPStrategy.UnauthorizedEmergencySweep.selector, caller, leftoverRecipient)
        );
        vm.prank(caller);
        strategy.emergencySweep(ILBPInitializer(address(initializer)));
    }

    function test_WhenBeforeUnlockBlock(MigrationFuzzParams memory p, uint64 _currentBlock) public {
        (MockLBPInitializer initializer,) = _setupForMigration(p);

        // _setupForMigration rolled to migrationBlock; pick any block strictly before migrationBlock + delay.
        uint256 unlock = p.migrationBlock + strategy.emergencySweepDelay();
        // Avoid wrapping when migrationBlock + delay overflows in extreme fuzz cases.
        vm.assume(unlock > block.number);
        _currentBlock = uint64(bound(_currentBlock, block.number, unlock - 1));
        vm.roll(_currentBlock);

        vm.expectRevert(abi.encodeWithSelector(ILBPStrategy.EmergencySweepNotAllowed.selector, unlock, _currentBlock));
        vm.prank(leftoverRecipient);
        strategy.emergencySweep(ILBPInitializer(address(initializer)));
    }

    function test_WhenAlreadyMigrated(MigrationFuzzParams memory p) public {
        (MockLBPInitializer initializer,) = _setupForMigration(p);

        strategy.migrate(ILBPInitializer(address(initializer)));
        assertEq(strategy.reserves(ILBPInitializer(address(initializer))), 0);

        // Even if we now wait past the unlock block, emergencySweep should reject because reserves are 0.
        vm.roll(p.migrationBlock + strategy.emergencySweepDelay());

        vm.expectRevert(
            abi.encodeWithSelector(ILBPStrategy.AlreadyConsumed.selector, ILBPInitializer(address(initializer)))
        );
        vm.prank(leftoverRecipient);
        strategy.emergencySweep(ILBPInitializer(address(initializer)));
    }

    function test_WhenAlreadyEmergencySwept(MigrationFuzzParams memory p) public {
        (MockLBPInitializer initializer,) = _setupForMigration(p);

        vm.roll(p.migrationBlock + strategy.emergencySweepDelay());
        vm.prank(leftoverRecipient);
        strategy.emergencySweep(ILBPInitializer(address(initializer)));

        // Second call should revert with AlreadyConsumed since reserves were zeroed.
        vm.expectRevert(
            abi.encodeWithSelector(ILBPStrategy.AlreadyConsumed.selector, ILBPInitializer(address(initializer)))
        );
        vm.prank(leftoverRecipient);
        strategy.emergencySweep(ILBPInitializer(address(initializer)));
    }

    function test_SweepsSupplyForLpToLeftoverRecipient(MigrationFuzzParams memory p) public {
        (MockLBPInitializer initializer, MockERC20 token) = _setupForMigration(p);
        uint128 supplyForLP = strategy.initializers(ILBPInitializer(address(initializer))).supplyForLP;

        uint256 strategyBalBefore = token.balanceOf(address(strategy));
        uint256 recipientBalBefore = token.balanceOf(leftoverRecipient);

        assertEq(strategy.reserves(ILBPInitializer(address(initializer))), supplyForLP);

        vm.roll(p.migrationBlock + strategy.emergencySweepDelay());

        vm.expectEmit(true, true, false, true, address(strategy));
        emit ILBPStrategy.EmergencySwept(ILBPInitializer(address(initializer)), leftoverRecipient, supplyForLP);
        vm.prank(leftoverRecipient);
        strategy.emergencySweep(ILBPInitializer(address(initializer)));

        assertEq(token.balanceOf(address(strategy)), strategyBalBefore - supplyForLP);
        assertEq(token.balanceOf(leftoverRecipient), recipientBalBefore + supplyForLP);
        // Reserves zeroed → blocks future consumption.
        assertEq(strategy.reserves(ILBPInitializer(address(initializer))), 0);
    }

    function test_BlocksFutureMigrateAfterSweep(MigrationFuzzParams memory p) public {
        (MockLBPInitializer initializer,) = _setupForMigration(p);

        vm.roll(p.migrationBlock + strategy.emergencySweepDelay());
        vm.prank(leftoverRecipient);
        strategy.emergencySweep(ILBPInitializer(address(initializer)));

        // migrate now fails with AlreadyConsumed (reserves == 0).
        vm.expectRevert(
            abi.encodeWithSelector(ILBPStrategy.AlreadyConsumed.selector, ILBPInitializer(address(initializer)))
        );
        strategy.migrate(ILBPInitializer(address(initializer)));
    }
}
