// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LBPStrategyTestBase} from "./base/LBPStrategyTestBase.sol";
import {ILBPStrategy} from "src/interfaces/ILBPStrategy.sol";
import {ILBPInitializer, LBPInitializationParams} from "src/interfaces/ILBPInitializer.sol";
import {MockLBPInitializer} from "test/mocks/MockLBPInitializer.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Vm} from "forge-std/Vm.sol";

contract LBPStrategy_ProtocolFee_Test is LBPStrategyTestBase {
    address feeRecipient = makeAddr("feeRecipient");

    function test_protocolFeeTransferredAndEmitted_native(FuzzParams memory p, uint256 _feeAmount) public {
        (MockLBPInitializer initializer,) = _setupForMigration(p);

        uint256 currencyRaised = initializer.lbpInitializationParams().currencyRaised;
        uint256 feeAmount = bound(_feeAmount, 1, currencyRaised);
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

    function test_protocolFeeTransferred_erc20Currency(FuzzParams memory p, uint256 _feeAmount) public {
        // Set up an ERC20 currency before initialization
        MockERC20 currencyToken = new MockERC20("Currency", "CUR", type(uint128).max, address(this));
        factory.setCurrencyOverride(address(currencyToken));

        (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock, uint128 auctionSupply) =
            _boundMigratorParams(p);
        p.currencyRaised = _boundCurrencyRaised(p.currencyRaised, mp.currencySplitForLP);
        p.initialPriceX96 = _boundInitialPriceX96(p.initialPriceX96);
        p.tokensSold = uint128(bound(p.tokensSold, 1, auctionSupply));

        (MockLBPInitializer initializer, MockERC20 token) = _initializeWith(mp, totalSupply, endBlock);
        initializer.setLbpInitializationParams(
            LBPInitializationParams({
                initialPriceX96: p.initialPriceX96, tokensSold: p.tokensSold, currencyRaised: p.currencyRaised
            })
        );
        currencyToken.transfer(address(initializer), p.currencyRaised);
        token.transfer(address(initializer), totalSupply);
        vm.roll(mp.migrationBlock);

        uint256 feeAmount = bound(_feeAmount, 1, p.currencyRaised);
        feeController.setMockFee(feeAmount, feeRecipient);

        vm.mockCall(address(POSITION_MANAGER), abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector), "");

        uint256 feeRecipientBalBefore = currencyToken.balanceOf(feeRecipient);

        vm.expectEmit(true, true, true, true);
        emit ILBPStrategy.ProtocolFeeTransferred(feeRecipient, feeAmount);
        strategy.migrate(ILBPInitializer(address(initializer)));

        assertEq(currencyToken.balanceOf(feeRecipient) - feeRecipientBalBefore, feeAmount);
        assertEq(currencyToken.balanceOf(address(strategy)), 0);
    }

    function test_noProtocolFeeEvent_whenFeeIsZero(FuzzParams memory p) public {
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

    function test_lpReceivesCurrencyMinusFee(FuzzParams memory p, uint256 _feeAmount) public {
        // Pin a moderate split so the math is predictable
        p.currencySplitForLP = uint24(bound(p.currencySplitForLP, 1e5, strategy.MAX_SPLIT_FOR_LP() - 1));

        (MockLBPInitializer initializer,) = _setupForMigration(p);
        uint256 currencyRaised = initializer.lbpInitializationParams().currencyRaised;

        uint256 feeAmount = bound(_feeAmount, 1, currencyRaised / 2);
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
