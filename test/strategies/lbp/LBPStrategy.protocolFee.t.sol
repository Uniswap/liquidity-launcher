// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LBPStrategyTestBase} from "./base/LBPStrategyTestBase.sol";
import {ILBPStrategy} from "src/interfaces/ILBPStrategy.sol";
import {ILBPInitializer, LBPInitializationParams} from "src/interfaces/ILBPInitializer.sol";
import {MockLBPInitializer} from "test/mocks/MockLBPInitializer.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {MigratorParams, MigratorParameters, LiquidityAllocationBracket} from "src/libraries/MigratorParams.sol";
import {ProtocolFeeController} from "src/periphery/ProtocolFeeController.sol";
import {IProtocolFeeController} from "src/interfaces/IProtocolFeeController.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

contract LBPStrategy_ProtocolFee_Test is LBPStrategyTestBase {
    address feeRecipient = makeAddr("feeRecipient");

    function setUp() public override {
        super.setUp();
        // Activate the controller: set the recipient so per-currency tier installs are allowed
        feeController.setProtocolFeeRecipient(feeRecipient);
    }

    /// @notice Strategy falls back to the global pips when no per-currency tier schedule is installed.
    function test_realController_globalFeeFallback_appliesGlobalPips(MigrationFuzzParams memory p, uint24 _pips)
        public
    {
        uint24 pips = uint24(bound(_pips, 1, feeController.PIPS_DENOMINATOR()));
        // Recipient already set in setUp; just set the global pips
        feeController.setGlobalProtocolFeePips(pips);
        // No per-currency schedule installed — strategy should hit the global-pips path

        LiquidityAllocationBracket[] memory bp = new LiquidityAllocationBracket[](1);
        bp[0] = LiquidityAllocationBracket({lowerThreshold: 0, rate: MigratorParams.MAX_BRACKET_RATE});

        uint256 currencyRaised = bound(p.currencyRaised, 1, type(uint256).max);
        uint256 expectedFee = FullMath.mulDiv(currencyRaised, pips, feeController.PIPS_DENOMINATOR());
        vm.assume(currencyRaised - expectedFee > 0);

        (MockLBPInitializer initializer,) = _setupForMigrationWithSchedule(p, bp, currencyRaised);

        uint256 feeBalBefore = feeRecipient.balance;
        uint256 fundsBalBefore = fundsRecipient.balance;
        uint256 poolBalBefore = address(POOL_MANAGER).balance;
        if (expectedFee > 0) {
            vm.expectEmit(true, true, true, true);
            emit ILBPStrategy.ProtocolFeeTransferred(feeRecipient, expectedFee);
        }
        strategy.migrate(ILBPInitializer(address(initializer)));

        uint256 feeDelta = feeRecipient.balance - feeBalBefore;
        uint256 fundsDelta = fundsRecipient.balance - fundsBalBefore;
        uint256 poolDelta = address(POOL_MANAGER).balance - poolBalBefore;

        assertEq(feeDelta, expectedFee);
        assertEq(feeDelta + fundsDelta + poolDelta, currencyRaised);
        assertEq(address(strategy).balance, 0);
    }

    function test_realController_oneTier_appliesFlatFeeToCurrencyRaised(MigrationFuzzParams memory p, uint24 _pips)
        public
    {
        uint24 pips = uint24(bound(_pips, 0, feeController.PIPS_DENOMINATOR()));

        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](1);
        fees[0] = IProtocolFeeController.Fee({lowerThreshold: 0, protocolFeePips: pips});
        _installFeeTiers(fees, address(0));

        LiquidityAllocationBracket[] memory bp = new LiquidityAllocationBracket[](1);
        bp[0] = LiquidityAllocationBracket({lowerThreshold: 0, rate: MigratorParams.MAX_BRACKET_RATE});

        uint256 currencyRaised = bound(p.currencyRaised, 1, type(uint256).max);
        uint256 expectedFee = FullMath.mulDiv(currencyRaised, pips, feeController.PIPS_DENOMINATOR());
        vm.assume(currencyRaised - expectedFee > 0);

        (MockLBPInitializer initializer,) = _setupForMigrationWithSchedule(p, bp, currencyRaised);

        uint256 feeBalBefore = feeRecipient.balance;
        uint256 fundsBalBefore = fundsRecipient.balance;
        uint256 poolBalBefore = address(POOL_MANAGER).balance;
        if (expectedFee > 0) {
            vm.expectEmit(true, true, true, true);
            emit ILBPStrategy.ProtocolFeeTransferred(feeRecipient, expectedFee);
        }
        strategy.migrate(ILBPInitializer(address(initializer)));

        uint256 feeDelta = feeRecipient.balance - feeBalBefore;
        uint256 fundsDelta = fundsRecipient.balance - fundsBalBefore;
        uint256 poolDelta = address(POOL_MANAGER).balance - poolBalBefore;

        assertEq(feeDelta, expectedFee);
        assertEq(feeDelta + fundsDelta + poolDelta, currencyRaised);
        assertEq(address(strategy).balance, 0);
    }

    function test_realController_twoTier_appliesTieredFeeToCurrencyRaised(
        MigrationFuzzParams memory p,
        uint24 _pips1,
        uint24 _pips2,
        uint256 _split
    ) public {
        uint24 pips1 = uint24(bound(_pips1, 0, feeController.PIPS_DENOMINATOR()));
        uint24 pips2 = uint24(bound(_pips2, 0, feeController.PIPS_DENOMINATOR()));
        uint256 split = bound(_split, 1, type(uint256).max);

        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](2);
        fees[0] = IProtocolFeeController.Fee({lowerThreshold: 0, protocolFeePips: pips1});
        fees[1] = IProtocolFeeController.Fee({lowerThreshold: split, protocolFeePips: pips2});
        _installFeeTiers(fees, address(0));

        // 100% LP bracket — every wei not taken as fee flows into the LP planner
        LiquidityAllocationBracket[] memory bp = new LiquidityAllocationBracket[](1);
        bp[0] = LiquidityAllocationBracket({lowerThreshold: 0, rate: MigratorParams.MAX_BRACKET_RATE});

        uint256 currencyRaised = bound(p.currencyRaised, 1, type(uint256).max);
        uint256 expectedFee = _refFeeTwoTier(currencyRaised, split, pips1, pips2);
        // Skip the 100%-fee case: post-fee = 0 starves the LP planner and v4 reverts on zero-delta ops
        vm.assume(currencyRaised - expectedFee > 0);

        (MockLBPInitializer initializer,) = _setupForMigrationWithSchedule(p, bp, currencyRaised);

        uint256 feeBalBefore = feeRecipient.balance;
        uint256 fundsBalBefore = fundsRecipient.balance;
        uint256 poolBalBefore = address(POOL_MANAGER).balance;
        // Strategy gates the emit on feeAmount > 0; only assert it when we expect a non-zero fee
        if (expectedFee > 0) {
            vm.expectEmit(true, true, true, true);
            emit ILBPStrategy.ProtocolFeeTransferred(feeRecipient, expectedFee);
        }
        strategy.migrate(ILBPInitializer(address(initializer)));

        uint256 feeDelta = feeRecipient.balance - feeBalBefore;
        uint256 fundsDelta = fundsRecipient.balance - fundsBalBefore;
        uint256 poolDelta = address(POOL_MANAGER).balance - poolBalBefore;

        assertEq(feeDelta, expectedFee);
        assertEq(feeDelta + fundsDelta + poolDelta, currencyRaised);
        assertEq(address(strategy).balance, 0);
    }

    function test_realController_threeTier_appliesTieredFeeToCurrencyRaised(
        MigrationFuzzParams memory p,
        uint24 _pips1,
        uint24 _pips2,
        uint24 _pips3,
        uint256 _split1,
        uint256 _split2
    ) public {
        uint256 currencyRaised = bound(p.currencyRaised, 1, type(uint256).max);
        uint256 expectedFee;
        {
            uint24 pips1 = uint24(bound(_pips1, 0, feeController.PIPS_DENOMINATOR()));
            uint24 pips2 = uint24(bound(_pips2, 0, feeController.PIPS_DENOMINATOR()));
            uint24 pips3 = uint24(bound(_pips3, 0, feeController.PIPS_DENOMINATOR()));
            uint256 split1 = bound(_split1, 1, type(uint256).max - 1);
            uint256 split2 = bound(_split2, split1 + 1, type(uint256).max);

            IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](3);
            fees[0] = IProtocolFeeController.Fee({lowerThreshold: 0, protocolFeePips: pips1});
            fees[1] = IProtocolFeeController.Fee({lowerThreshold: split1, protocolFeePips: pips2});
            fees[2] = IProtocolFeeController.Fee({lowerThreshold: split2, protocolFeePips: pips3});
            _installFeeTiers(fees, address(0));

            expectedFee = _refFeeThreeTier(currencyRaised, split1, split2, pips1, pips2, pips3);
        }
        // Skip the 100%-fee case: post-fee = 0 starves the LP planner and v4 reverts on zero-delta ops
        vm.assume(currencyRaised - expectedFee > 0);

        LiquidityAllocationBracket[] memory bp = new LiquidityAllocationBracket[](1);
        bp[0] = LiquidityAllocationBracket({lowerThreshold: 0, rate: MigratorParams.MAX_BRACKET_RATE});

        (MockLBPInitializer initializer,) = _setupForMigrationWithSchedule(p, bp, currencyRaised);

        uint256 feeBalBefore = feeRecipient.balance;
        uint256 fundsBalBefore = fundsRecipient.balance;
        uint256 poolBalBefore = address(POOL_MANAGER).balance;
        // Strategy gates the emit on feeAmount > 0; only assert it when we expect a non-zero fee
        if (expectedFee > 0) {
            vm.expectEmit(true, true, true, true);
            emit ILBPStrategy.ProtocolFeeTransferred(feeRecipient, expectedFee);
        }
        strategy.migrate(ILBPInitializer(address(initializer)));

        uint256 feeDelta = feeRecipient.balance - feeBalBefore;
        uint256 fundsDelta = fundsRecipient.balance - fundsBalBefore;
        uint256 poolDelta = address(POOL_MANAGER).balance - poolBalBefore;

        assertEq(feeDelta, expectedFee);
        assertEq(feeDelta + fundsDelta + poolDelta, currencyRaised);
        assertEq(address(strategy).balance, 0);
    }

    function test_realController_appliesTieredFeeToErc20Currency(
        MigrationFuzzParams memory p,
        uint24 _pips1,
        uint24 _pips2,
        uint256 _split
    ) public {
        MockERC20 currencyToken = new MockERC20("Currency", "CUR", type(uint128).max, address(this));
        factory.setCurrencyOverride(address(currencyToken));

        uint256 currencyRaised = bound(p.currencyRaised, 1, type(uint128).max);
        uint256 expectedFee;
        {
            uint24 pips1 = uint24(bound(_pips1, 0, feeController.PIPS_DENOMINATOR()));
            uint24 pips2 = uint24(bound(_pips2, 0, feeController.PIPS_DENOMINATOR()));
            uint256 split = bound(_split, 1, type(uint256).max);

            IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](2);
            fees[0] = IProtocolFeeController.Fee({lowerThreshold: 0, protocolFeePips: pips1});
            fees[1] = IProtocolFeeController.Fee({lowerThreshold: split, protocolFeePips: pips2});
            _installFeeTiers(fees, address(currencyToken));

            expectedFee = _refFeeTwoTier(currencyRaised, split, pips1, pips2);
        }
        vm.assume(currencyRaised - expectedFee > 0);

        // _setupForMigrationWithSchedule uses vm.deal (ETH-only), so use an ERC20-specific helper
        MockLBPInitializer initializer = _setupErc20Migration(p, currencyToken, currencyRaised);

        uint256 feeBalBefore = currencyToken.balanceOf(feeRecipient);
        uint256 fundsBalBefore = currencyToken.balanceOf(fundsRecipient);
        uint256 poolBalBefore = currencyToken.balanceOf(address(POOL_MANAGER));

        if (expectedFee > 0) {
            vm.expectEmit(true, true, true, true);
            emit ILBPStrategy.ProtocolFeeTransferred(feeRecipient, expectedFee);
        }
        strategy.migrate(ILBPInitializer(address(initializer)));

        uint256 feeDelta = currencyToken.balanceOf(feeRecipient) - feeBalBefore;
        uint256 fundsDelta = currencyToken.balanceOf(fundsRecipient) - fundsBalBefore;
        uint256 poolDelta = currencyToken.balanceOf(address(POOL_MANAGER)) - poolBalBefore;

        assertEq(feeDelta, expectedFee);
        assertEq(feeDelta + fundsDelta + poolDelta, currencyRaised);
        assertEq(currencyToken.balanceOf(address(strategy)), 0);
    }

    /// @dev ERC20 equivalent of _setupForMigrationWithSchedule with a 100% LP bracket. Uses
    /// currencyToken.transfer instead of vm.deal so the initializer is funded with ERC20.
    function _setupErc20Migration(MigrationFuzzParams memory p, MockERC20 currencyToken, uint256 currencyRaised)
        internal
        returns (MockLBPInitializer initializer)
    {
        LiquidityAllocationBracket[] memory bp = new LiquidityAllocationBracket[](1);
        bp[0] = LiquidityAllocationBracket({lowerThreshold: 0, rate: MigratorParams.MAX_BRACKET_RATE});
        (MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock, uint128 auctionSupply) =
            _boundMigratorParams(p);
        p.initialPriceX96 = _boundInitialPriceX96(p.initialPriceX96);
        p.tokensSold = uint128(bound(p.tokensSold, 1, auctionSupply));

        MockERC20 token;
        (initializer, token) = _initializeWith(mp, totalSupply, endBlock, bp);
        initializer.setLbpInitializationParams(
            LBPInitializationParams({
                initialPriceX96: p.initialPriceX96, tokensSold: p.tokensSold, currencyRaised: currencyRaised
            })
        );
        currencyToken.transfer(address(initializer), currencyRaised);
        token.transfer(address(initializer), totalSupply);
        vm.roll(mp.migrationBlock);
    }

    /// @dev Installs a per-currency tier schedule on the controller. Tier-math fuzz coverage lives in
    /// the controller's own test file; these tests verify the strategy's integration with a real
    /// (non-mock) controller producing a tier-derived fee.
    function _installFeeTiers(IProtocolFeeController.Fee[] memory fees, address currency) internal {
        feeController.setProtocolFeePerCurrency(currency, fees);
    }

    /// @dev Reference implementation for two-tier fee math (mirrors the controller's own test helper).
    /// Uses FullMath to match the controller's 512-bit-intermediate multiply for uint256 amounts.
    function _refFeeTwoTier(uint256 amount, uint256 split, uint24 pips1, uint24 pips2) internal view returns (uint256) {
        uint24 denom = feeController.PIPS_DENOMINATOR();
        uint256 tier1 = amount > split ? split : amount;
        uint256 fee = FullMath.mulDiv(tier1, pips1, denom);
        if (amount > split) {
            fee += FullMath.mulDiv(amount - split, pips2, denom);
        }
        return fee;
    }

    /// @dev Reference implementation for three-tier fee math (mirrors the controller's own test helper).
    function _refFeeThreeTier(uint256 amount, uint256 split1, uint256 split2, uint24 pips1, uint24 pips2, uint24 pips3)
        internal
        view
        returns (uint256 fee)
    {
        uint24 denom = feeController.PIPS_DENOMINATOR();
        uint256 tier1 = amount > split1 ? split1 : amount;
        fee += FullMath.mulDiv(tier1, pips1, denom);
        if (amount <= split1) return fee;

        uint256 tier2 = (amount > split2 ? split2 : amount) - split1;
        fee += FullMath.mulDiv(tier2, pips2, denom);
        if (amount <= split2) return fee;

        fee += FullMath.mulDiv(amount - split2, pips3, denom);
    }
}
