// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LBPStrategyTestBase} from "./base/LBPStrategyTestBase.sol";
import {ILBPStrategy} from "src/interfaces/ILBPStrategy.sol";
import {ILBPInitializer, LBPInitializationParams} from "src/interfaces/ILBPInitializer.sol";
import {MockLBPInitializer} from "test/mocks/MockLBPInitializer.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {MigratorParameters, LiquidityAllocationBracket} from "src/libraries/MigratorParams.sol";

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

        uint256 feeRecipientBalBefore = currencyToken.balanceOf(feeRecipient);

        vm.expectEmit(true, true, true, true);
        emit ILBPStrategy.ProtocolFeeTransferred(feeRecipient, feeAmount);
        strategy.migrate(ILBPInitializer(address(initializer)));

        assertEq(currencyToken.balanceOf(feeRecipient) - feeRecipientBalBefore, feeAmount);
        assertEq(currencyToken.balanceOf(address(strategy)), 0);
    }

    function test_noProtocolFeeTransferred_whenFeeIsZero(MigrationFuzzParams memory p) public {
        (MockLBPInitializer initializer,) = _setupForMigration(p);
        // Mock defaults to (0, address(0)) — explicit for clarity
        feeController.setMockFee(0, address(0));

        uint256 feeRecipientBalBefore = feeRecipient.balance;
        strategy.migrate(ILBPInitializer(address(initializer)));

        // No transfer occurred — fee path is guarded by `if (feeAmount > 0)`,
        // which also gates the ProtocolFeeTransferred event emission.
        assertEq(feeRecipient.balance, feeRecipientBalBefore);
    }

    function test_lpReceivesCurrencyMinusFee(MigrationFuzzParams memory p, uint256 _feeAmount) public {
        LiquidityAllocationBracket[] memory brackets = _boundBrackets(p.bpParams);
        (MockLBPInitializer initializer,) = _setupForMigration(p);
        uint256 currencyRaised = initializer.lbpInitializationParams().currencyRaised;

        uint256 feeAmount = _boundFeeAmount(_feeAmount, currencyRaised, brackets);
        vm.assume(feeAmount > 0);
        feeController.setMockFee(feeAmount, feeRecipient);

        uint256 feeRecipientBalBefore = feeRecipient.balance;
        uint256 fundsRecipientBalBefore = fundsRecipient.balance;
        uint256 poolManagerBalBefore = address(POOL_MANAGER).balance;

        strategy.migrate(ILBPInitializer(address(initializer)));

        // Fee is transferred to fee recipient
        assertEq(feeRecipient.balance - feeRecipientBalBefore, feeAmount);
        // Everything else is either at fundsRecipient or locked in the pool — nothing lost
        assertEq(
            (fundsRecipient.balance - fundsRecipientBalBefore) + (address(POOL_MANAGER).balance - poolManagerBalBefore),
            currencyRaised - feeAmount
        );
        assertEq(address(strategy).balance, 0);
    }
}
