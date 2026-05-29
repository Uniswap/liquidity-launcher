// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LBPStrategyTestBase} from "../../../base/LBPStrategyTestBase.sol";
import {ILBPStrategy} from "src/interfaces/ILBPStrategy.sol";
import {ILBPInitializer, LBPInitializationParams} from "src/interfaces/ILBPInitializer.sol";
import {MigratorParameters, LiquidityAllocationBracket} from "src/libraries/MigratorParams.sol";
import {MockLBPInitializer} from "test/mocks/MockLBPInitializer.sol";
import {MockReentrantRecoverFundsRecipient} from "test/mocks/MockReentrantRecoverFundsRecipient.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";

/// @title RecoverFundsTest
/// @notice BTT tests for LBPStrategy.recoverFunds
///
/// recoverFunds
/// ├── when initializer is unregistered (migrationBlock == 0)
/// │   └── it reverts with InitializerNotRegistered
/// ├── when initializer was already migrated
/// │   └── it reverts with InsufficientReserves
/// ├── when initializer was already recovered
/// │   └── it reverts with InsufficientReserves
/// ├── when caller != recipient
/// │   └── it reverts with UnauthorizedRecovery
/// ├── when block.number < migrationBlock + recoveryDelayBlocks
/// │   └── it reverts with RecoveryNotYetAllowed
/// └── when called by recipient at or past the unlock block on a live initializer
///     ├── it transfers reservedTokenAmountForLP from strategy to recipient
///     ├── it zeroes reserves (blocks future migrate and recoverFunds)
///     └── it emits FundsRecovered
contract RecoverFundsTest is LBPStrategyTestBase {
    function test_WhenInitializerIsInitializerNotRegistered() public {
        ILBPInitializer unregistered = ILBPInitializer(
            address(new MockLBPInitializer(address(1), address(0), 0, address(strategy), address(strategy), 0, 0))
        );

        // migrationBlock == 0 distinguishes unregistered from consumed.
        assertEq(strategy.initializers(unregistered).migrationBlock, 0);

        vm.expectRevert(abi.encodeWithSelector(ILBPStrategy.InitializerNotRegistered.selector, unregistered));
        strategy.recoverFunds(unregistered);
    }

    function test_WhenCallerIsNotRecipient(MigrationFuzzParams memory p, address caller) public {
        (MockLBPInitializer initializer,) = _setupForMigration(p);
        vm.assume(caller != recipient);

        // Roll past the unlock block so the "too early" check passes and we reach the auth check.
        vm.roll(p.migrationBlock + strategy.recoveryDelayBlocks());

        vm.expectRevert(abi.encodeWithSelector(ILBPStrategy.UnauthorizedRecovery.selector, caller, recipient));
        vm.prank(caller);
        strategy.recoverFunds(ILBPInitializer(address(initializer)));
    }

    function test_WhenBeforeUnlockBlock(MigrationFuzzParams memory p, uint64 _currentBlock) public {
        (MockLBPInitializer initializer,) = _setupForMigration(p);

        // _setupForMigration rolled to migrationBlock; pick any block strictly before migrationBlock + delay.
        uint256 unlock = p.migrationBlock + strategy.recoveryDelayBlocks();
        // Avoid wrapping when migrationBlock + delay overflows in extreme fuzz cases.
        vm.assume(unlock > block.number);
        _currentBlock = uint64(bound(_currentBlock, block.number, unlock - 1));
        vm.roll(_currentBlock);

        vm.expectRevert(abi.encodeWithSelector(ILBPStrategy.RecoveryNotYetAllowed.selector, unlock));
        vm.prank(recipient);
        strategy.recoverFunds(ILBPInitializer(address(initializer)));
    }

    function test_WhenAlreadyMigrated(MigrationFuzzParams memory p) public {
        (MockLBPInitializer initializer,) = _setupForMigration(p);

        strategy.migrate(ILBPInitializer(address(initializer)));
        assertEq(strategy.reserves(ILBPInitializer(address(initializer))), 0);

        // Even if we now wait past the unlock block, recoverFunds should reject because reserves are 0.
        vm.roll(p.migrationBlock + strategy.recoveryDelayBlocks());

        vm.expectRevert(
            abi.encodeWithSelector(ILBPStrategy.InsufficientReserves.selector, ILBPInitializer(address(initializer)))
        );
        vm.prank(recipient);
        strategy.recoverFunds(ILBPInitializer(address(initializer)));
    }

    function test_WhenAlreadyRecovered(MigrationFuzzParams memory p) public {
        (MockLBPInitializer initializer,) = _setupForMigration(p);

        vm.roll(p.migrationBlock + strategy.recoveryDelayBlocks());
        vm.prank(recipient);
        strategy.recoverFunds(ILBPInitializer(address(initializer)));

        // Second call should revert with InsufficientReserves since reserves were zeroed.
        vm.expectRevert(
            abi.encodeWithSelector(ILBPStrategy.InsufficientReserves.selector, ILBPInitializer(address(initializer)))
        );
        vm.prank(recipient);
        strategy.recoverFunds(ILBPInitializer(address(initializer)));
    }

    function test_SweepsReservetokenAmountForLPToRecipient(MigrationFuzzParams memory p) public {
        (MockLBPInitializer initializer, MockERC20 token) = _setupForMigration(p);
        uint128 reservedTokenAmountForLP =
            strategy.initializers(ILBPInitializer(address(initializer))).reservedTokenAmountForLP;

        uint256 strategyBalBefore = token.balanceOf(address(strategy));
        uint256 recipientBalBefore = token.balanceOf(recipient);

        assertEq(strategy.reserves(ILBPInitializer(address(initializer))), reservedTokenAmountForLP);

        vm.roll(p.migrationBlock + strategy.recoveryDelayBlocks());

        vm.expectEmit(true, true, false, true, address(strategy));
        emit ILBPStrategy.FundsRecovered(ILBPInitializer(address(initializer)), recipient, reservedTokenAmountForLP);
        vm.prank(recipient);
        strategy.recoverFunds(ILBPInitializer(address(initializer)));

        assertEq(token.balanceOf(address(strategy)), strategyBalBefore - reservedTokenAmountForLP);
        assertEq(token.balanceOf(recipient), recipientBalBefore + reservedTokenAmountForLP);
        // Reserves zeroed → blocks future consumption.
        assertEq(strategy.reserves(ILBPInitializer(address(initializer))), 0);
    }

    /// @notice Currency raised in the initializer must also be recovered to recipient — otherwise
    /// migrate-never-called would brick the auction proceeds. recoverFunds calls sweepCurrency on
    /// the initializer and forwards the delta atomically with the reservedTokenAmountForLP transfer.
    function test_SweepsInitializerCurrencyToRecipient(MigrationFuzzParams memory p) public {
        (MockLBPInitializer initializer, MockERC20 token) = _setupForMigration(p);
        uint256 raised = initializer.lbpInitializationParams().currencyRaised;
        uint128 reservedTokenAmountForLP =
            strategy.initializers(ILBPInitializer(address(initializer))).reservedTokenAmountForLP;
        uint256 leftoverEthBefore = recipient.balance;
        uint256 leftoverTokenBefore = token.balanceOf(recipient);

        // migrate is never called.
        vm.roll(p.migrationBlock + strategy.recoveryDelayBlocks());

        vm.prank(recipient);
        strategy.recoverFunds(ILBPInitializer(address(initializer)));

        // reservedTokenAmountForLP forwarded
        assertEq(token.balanceOf(recipient), leftoverTokenBefore + reservedTokenAmountForLP);
        assertEq(token.balanceOf(address(strategy)), 0);
        // initializer's raised currency forwarded too (no longer bricked)
        assertEq(recipient.balance, leftoverEthBefore + raised);
        assertEq(address(initializer).balance, 0);
    }

    /// @notice When the auction raised no currency, recoverFunds still consumes the reservation
    /// and forwards reservedTokenAmountForLP, but skips the currency-transfer leg and does NOT emit CurrencySwept.
    function test_fuzz_doesNotEmitCurrencySweptWhenCurrencyRaisedIsZero(MigrationFuzzParams memory p) public {
        LiquidityAllocationBracket[] memory brackets = _boundBrackets(p.bpParams);
        (MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock,) = _boundMigratorParams(p);

        // Force a zero-raise scenario. initializer is registered honestly with currencyRaised = 0.
        LBPInitializationParams memory lbpParams =
            LBPInitializationParams({initialPriceX96: 0, tokensSold: 0, currencyRaised: 0});
        (MockLBPInitializer initializer, MockERC20 token) =
            _initializeWith(mp, totalSupply, endBlock, brackets, address(0), lbpParams);

        vm.roll(mp.migrationBlock + strategy.recoveryDelayBlocks());

        uint256 ethBefore = recipient.balance;
        uint256 tokenBefore = token.balanceOf(recipient);

        vm.prank(recipient);
        strategy.recoverFunds(ILBPInitializer(address(initializer)));

        // Token side: reservedTokenAmountForLP forwarded normally.
        assertEq(token.balanceOf(recipient), tokenBefore + mp.reservedTokenAmountForLP);
        // Currency side: no transfer (the `if (recoveredCurrency > 0)` branch is skipped). The
        // unchanged ETH balance is sufficient proof that the currency-transfer leg didn't fire.
        assertEq(recipient.balance, ethBefore);
    }

    /// @notice Currency-side recovery works when the auction currency is an ERC20 (not native ETH).
    /// Exercises the ERC20 branch of CurrencyLibrary.transfer inside recoverFunds.
    function test_fuzz_sweepsErc20CurrencyToRecipient(MigrationFuzzParams memory p) public {
        MockERC20 currencyToken = new MockERC20("Currency", "CUR", type(uint128).max, address(this));

        LiquidityAllocationBracket[] memory brackets = _boundBrackets(p.bpParams);
        p.currencyRaised = _boundCurrencyRaised(p.currencyRaised, brackets);
        (MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock, uint128 auctionSupply) =
            _boundMigratorParams(p);
        p.initialPriceX96 = _boundInitialPriceX96(p.initialPriceX96);
        p.tokensSold = uint128(bound(p.tokensSold, 1, auctionSupply));

        LBPInitializationParams memory lbpParams = LBPInitializationParams({
            initialPriceX96: p.initialPriceX96, tokensSold: p.tokensSold, currencyRaised: p.currencyRaised
        });
        (MockLBPInitializer initializer, MockERC20 token) =
            _initializeWith(mp, totalSupply, endBlock, brackets, address(currencyToken), lbpParams);

        // Fund the initializer with the ERC20 currency it claims to have raised.
        deal(address(currencyToken), address(initializer), p.currencyRaised);

        vm.roll(mp.migrationBlock + strategy.recoveryDelayBlocks());

        uint256 currencyBefore = currencyToken.balanceOf(recipient);
        uint256 tokenBefore = token.balanceOf(recipient);

        vm.prank(recipient);
        strategy.recoverFunds(ILBPInitializer(address(initializer)));

        // ERC20 currency forwarded to recipient.
        assertEq(currencyToken.balanceOf(recipient), currencyBefore + p.currencyRaised);
        assertEq(currencyToken.balanceOf(address(initializer)), 0);
        // Token side: reservedTokenAmountForLP forwarded.
        assertEq(token.balanceOf(recipient), tokenBefore + mp.reservedTokenAmountForLP);
    }

    /// @notice A malicious recipient that reenters recoverFunds(self) from its receive()
    function test_fuzz_recoverFundsReentryViaRecipient_revertsWithReentrancy(MigrationFuzzParams memory p) public {
        MockReentrantRecoverFundsRecipient recipient =
            new MockReentrantRecoverFundsRecipient(ILBPStrategy(address(strategy)));

        LiquidityAllocationBracket[] memory brackets = _boundBrackets(p.bpParams);
        p.currencyRaised = _boundCurrencyRaised(p.currencyRaised, brackets);
        (MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock, uint128 auctionSupply) =
            _boundMigratorParams(p);
        p.initialPriceX96 = _boundInitialPriceX96(p.initialPriceX96);
        p.tokensSold = uint128(bound(p.tokensSold, 1, auctionSupply));

        mp.recipient = address(recipient);

        LBPInitializationParams memory lbpParams = LBPInitializationParams({
            initialPriceX96: p.initialPriceX96, tokensSold: p.tokensSold, currencyRaised: p.currencyRaised
        });
        (MockLBPInitializer initializer,) = _initializeWith(mp, totalSupply, endBlock, brackets, address(0), lbpParams);

        vm.deal(address(initializer), p.currencyRaised);
        recipient.setInitializer(ILBPInitializer(address(initializer)));

        vm.roll(mp.migrationBlock + strategy.recoveryDelayBlocks());
        vm.prank(address(recipient));
        strategy.recoverFunds(ILBPInitializer(address(initializer)));

        assertTrue(recipient.reentered());
        assertEq(bytes4(recipient.capturedRevertData()), ReentrancyGuardTransient.Reentrancy.selector);
    }

    function test_BlocksFutureMigrateAfterSweep(MigrationFuzzParams memory p) public {
        (MockLBPInitializer initializer,) = _setupForMigration(p);

        vm.roll(p.migrationBlock + strategy.recoveryDelayBlocks());
        vm.prank(recipient);
        strategy.recoverFunds(ILBPInitializer(address(initializer)));

        // migrate now fails with InsufficientReserves (reserves == 0).
        vm.expectRevert(
            abi.encodeWithSelector(ILBPStrategy.InsufficientReserves.selector, ILBPInitializer(address(initializer)))
        );
        strategy.migrate(ILBPInitializer(address(initializer)));
    }
}
