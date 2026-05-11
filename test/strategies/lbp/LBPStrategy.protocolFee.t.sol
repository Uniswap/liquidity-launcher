// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LBPStrategyTestBase} from "./base/LBPStrategyTestBase.sol";
import {ILBPStrategy} from "src/interfaces/ILBPStrategy.sol";
import {ILBPInitializer, LBPInitializationParams} from "src/interfaces/ILBPInitializer.sol";
import {MockLBPInitializer} from "test/mocks/MockLBPInitializer.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {MigratorParameters, LiquidityAllocationBracket} from "src/libraries/MigratorParams.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Vm} from "forge-std/Vm.sol";

contract LBPStrategy_ProtocolFee_Test is LBPStrategyTestBase {
    address feeRecipient = makeAddr("feeRecipient");

    /// @dev Bound the fee to leave at least the minimum currency needed for non-zero LP after deduction.
    function _boundFeeAmount(uint256 _feeAmount, uint256 currencyRaised, LiquidityAllocationBracket[] memory brackets)
        internal
        pure
        returns (uint256)
    {
        uint256 minLpCurrency = _minCurrencyForNonZeroLp(brackets);
        // Guaranteed by _boundCurrencyRaised: currencyRaised >= minLpCurrency
        uint256 maxFee = currencyRaised - minLpCurrency;
        if (maxFee == 0) return 0;
        return bound(_feeAmount, 1, maxFee);
    }

    function test_protocolFeeTransferredAndEmitted_native(MigrationFuzzParams memory p, uint256 _feeAmount) public {
        LiquidityAllocationBracket[] memory brackets = _boundBrackets(p.bpParams);
        (MockLBPInitializer initializer,) = _setupForMigration(p);

        uint256 currencyRaised = initializer.lbpInitializationParams().currencyRaised;
        uint256 feeAmount = _boundFeeAmount(_feeAmount, currencyRaised, brackets);
        vm.assume(feeAmount > 0);
        feeController.setMockFee(feeAmount, feeRecipient);

        // Skip pool execution; we're validating the fee path, not LP creation
        vm.mockCall(address(POSITION_MANAGER), abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector), "");

        uint256 feeRecipientBalBefore = feeRecipient.balance;

        vm.expectEmit(true, true, true, true);
        emit ILBPStrategy.ProtocolFeeTransferred(feeRecipient, feeAmount);
        strategy.migrate(ILBPInitializer(address(initializer)));

        assertEq(feeRecipient.balance - feeRecipientBalBefore, feeAmount);
        assertEq(address(strategy).balance, 0);
    }

    function test_protocolFeeTransferred_erc20Currency(MigrationFuzzParams memory p, uint256 _feeAmount) public {
        // Set up an ERC20 currency before initialization
        MockERC20 currencyToken = new MockERC20("Currency", "CUR", type(uint128).max, address(this));
        factory.setCurrencyOverride(address(currencyToken));

        LiquidityAllocationBracket[] memory brackets = _boundBrackets(p.bpParams);
        (MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock, uint128 auctionSupply) =
            _boundMigratorParams(p);
        p.currencyRaised = _boundCurrencyRaised(p.currencyRaised, brackets);
        p.initialPriceX96 = _boundInitialPriceX96(p.initialPriceX96);
        p.tokensSold = uint128(bound(p.tokensSold, 1, auctionSupply));

        (MockLBPInitializer initializer, MockERC20 token) = _initializeWith(mp, totalSupply, endBlock, brackets);
        initializer.setLbpInitializationParams(
            LBPInitializationParams({
                initialPriceX96: p.initialPriceX96, tokensSold: p.tokensSold, currencyRaised: p.currencyRaised
            })
        );
        currencyToken.transfer(address(initializer), p.currencyRaised);
        token.transfer(address(initializer), totalSupply);
        vm.roll(mp.migrationBlock);

        uint256 feeAmount = _boundFeeAmount(_feeAmount, p.currencyRaised, brackets);
        vm.assume(feeAmount > 0);
        feeController.setMockFee(feeAmount, feeRecipient);

        vm.mockCall(address(POSITION_MANAGER), abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector), "");

        uint256 feeRecipientBalBefore = currencyToken.balanceOf(feeRecipient);

        vm.expectEmit(true, true, true, true);
        emit ILBPStrategy.ProtocolFeeTransferred(feeRecipient, feeAmount);
        strategy.migrate(ILBPInitializer(address(initializer)));

        assertEq(currencyToken.balanceOf(feeRecipient) - feeRecipientBalBefore, feeAmount);
        assertEq(currencyToken.balanceOf(address(strategy)), 0);
    }

    function test_noProtocolFeeEvent_whenFeeIsZero(MigrationFuzzParams memory p) public {
        (MockLBPInitializer initializer,) = _setupForMigration(p);
        // Mock defaults to (0, address(0)) — explicit for clarity
        feeController.setMockFee(0, address(0));

        vm.mockCall(address(POSITION_MANAGER), abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector), "");

        vm.recordLogs();
        strategy.migrate(ILBPInitializer(address(initializer)));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = ILBPStrategy.ProtocolFeeTransferred.selector;
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != sig);
        }
    }

    function test_lpReceivesCurrencyMinusFee(MigrationFuzzParams memory p, uint256 _feeAmount) public {
        LiquidityAllocationBracket[] memory brackets = _boundBrackets(p.bpParams);
        (MockLBPInitializer initializer,) = _setupForMigration(p);
        uint256 currencyRaised = initializer.lbpInitializationParams().currencyRaised;

        uint256 feeAmount = _boundFeeAmount(_feeAmount, currencyRaised, brackets);
        vm.assume(feeAmount > 0);
        feeController.setMockFee(feeAmount, feeRecipient);

        // Mock LP creation so all non-fee currency ends up at fundsRecipient via the post-sweep
        vm.mockCall(address(POSITION_MANAGER), abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector), "");

        uint256 feeRecipientBalBefore = feeRecipient.balance;
        uint256 fundsRecipientBalBefore = fundsRecipient.balance;

        strategy.migrate(ILBPInitializer(address(initializer)));

        assertEq(feeRecipient.balance - feeRecipientBalBefore, feeAmount);
        // With modifyLiquidities mocked, currencyRaised - feeAmount ends up at fundsRecipient (within rounding)
        assertApproxEqAbs(fundsRecipient.balance - fundsRecipientBalBefore, currencyRaised - feeAmount, 2);
        assertEq(address(strategy).balance, 0);
    }
}
