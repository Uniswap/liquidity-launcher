// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ProtocolFeeController} from "../../src/periphery/ProtocolFeeController.sol";
import {IProtocolFeeController} from "../../src/interfaces/IProtocolFeeController.sol";

contract ProtocolFeeControllerTest is Test {
    ProtocolFeeController public controller;

    uint24 constant BPS = 10_000;
    address recipient = makeAddr("recipient");
    address nonOwner = makeAddr("nonOwner");
    address currency = makeAddr("currency");

    function setUp() public {
        controller = new ProtocolFeeController();
        // Set a default global fee for tests that need it
        controller.setGlobalProtocolFeeSettings(500, recipient);
    }

    // ══════════════════════════════════════════════════════════════════════
    // setGlobalProtocolFeeSettings
    // ══════════════════════════════════════════════════════════════════════

    function test_setGlobalProtocolFeeSettings_revertsWhenNotOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert("UNAUTHORIZED");
        controller.setGlobalProtocolFeeSettings(500, recipient);
    }

    function test_setGlobalProtocolFeeSettings_revertsWhenBpsExceedsBPS() public {
        vm.expectRevert(IProtocolFeeController.InvalidInput.selector);
        controller.setGlobalProtocolFeeSettings(10_001, recipient);
    }

    function test_setGlobalProtocolFeeSettings_revertsWhenRecipientIsZero() public {
        vm.expectRevert(IProtocolFeeController.InvalidInput.selector);
        controller.setGlobalProtocolFeeSettings(500, address(0));
    }

    function test_setGlobalProtocolFeeSettings_setsAndEmits() public {
        address newRecipient = makeAddr("newRecipient");
        vm.expectEmit(true, true, true, true);
        emit IProtocolFeeController.GlobalProtocolFeeSettingsUpdated(300, newRecipient);
        controller.setGlobalProtocolFeeSettings(300, newRecipient);

        (uint24 bps, address r) = controller.globalProtocolFee();
        assertEq(bps, 300);
        assertEq(r, newRecipient);
    }

    function test_setGlobalProtocolFeeSettings_allowsZeroBps() public {
        controller.setGlobalProtocolFeeSettings(0, recipient);
        (uint24 bps,) = controller.globalProtocolFee();
        assertEq(bps, 0);
    }

    function test_setGlobalProtocolFeeSettings_allowsMaxBps() public {
        controller.setGlobalProtocolFeeSettings(BPS, recipient);
        (uint24 bps,) = controller.globalProtocolFee();
        assertEq(bps, BPS);
    }

    // ══════════════════════════════════════════════════════════════════════
    // setProtocolFeePerCurrency — reverts
    // ══════════════════════════════════════════════════════════════════════

    function test_setProtocolFeePerCurrency_revertsWhenNotOwner() public {
        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](1);
        fees[0] = IProtocolFeeController.Fee({startAmount: 0, protocolFeeBps: 200});

        vm.prank(nonOwner);
        vm.expectRevert("UNAUTHORIZED");
        controller.setProtocolFeePerCurrency(currency, 18, fees, 0);
    }

    function test_setProtocolFeePerCurrency_revertsWhenLengthExceeds3() public {
        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](4);
        fees[0] = IProtocolFeeController.Fee({startAmount: 0, protocolFeeBps: 100});
        fees[1] = IProtocolFeeController.Fee({startAmount: 10, protocolFeeBps: 200});
        fees[2] = IProtocolFeeController.Fee({startAmount: 20, protocolFeeBps: 300});
        fees[3] = IProtocolFeeController.Fee({startAmount: 30, protocolFeeBps: 400});

        vm.expectRevert(abi.encodeWithSelector(IProtocolFeeController.InvalidFeeLength.selector, 4, 3));
        controller.setProtocolFeePerCurrency(currency, 18, fees, 0);
    }

    function test_setProtocolFeePerCurrency_revertsWhenScaleExceeds68() public {
        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](1);
        fees[0] = IProtocolFeeController.Fee({startAmount: 0, protocolFeeBps: 200});

        vm.expectRevert(abi.encodeWithSelector(IProtocolFeeController.InvalidScale.selector, 69, 68));
        controller.setProtocolFeePerCurrency(currency, 69, fees, 0);
    }

    function test_setProtocolFeePerCurrency_revertsWhenFirstStartAmountNonZero() public {
        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](1);
        fees[0] = IProtocolFeeController.Fee({startAmount: 1, protocolFeeBps: 200});

        vm.expectRevert(IProtocolFeeController.InvalidInput.selector);
        controller.setProtocolFeePerCurrency(currency, 18, fees, 0);
    }

    function test_setProtocolFeePerCurrency_revertsWhenStartAmountsNotAscending() public {
        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](2);
        fees[0] = IProtocolFeeController.Fee({startAmount: 0, protocolFeeBps: 200});
        fees[1] = IProtocolFeeController.Fee({startAmount: 0, protocolFeeBps: 100});

        vm.expectRevert(IProtocolFeeController.InvalidInput.selector);
        controller.setProtocolFeePerCurrency(currency, 18, fees, 0);
    }

    function test_setProtocolFeePerCurrency_revertsWhenFeeBpsExceedsBPS() public {
        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](1);
        fees[0] = IProtocolFeeController.Fee({startAmount: 0, protocolFeeBps: 10_001});

        vm.expectRevert(IProtocolFeeController.InvalidInput.selector);
        controller.setProtocolFeePerCurrency(currency, 18, fees, 0);
    }

    function test_setProtocolFeePerCurrency_revertsWhenCapEqualsLastStart() public {
        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](2);
        fees[0] = IProtocolFeeController.Fee({startAmount: 0, protocolFeeBps: 200});
        fees[1] = IProtocolFeeController.Fee({startAmount: 100, protocolFeeBps: 100});

        vm.expectRevert(IProtocolFeeController.InvalidInput.selector);
        controller.setProtocolFeePerCurrency(currency, 18, fees, 100);
    }

    function test_setProtocolFeePerCurrency_revertsWhenCapLessThanLastStart() public {
        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](2);
        fees[0] = IProtocolFeeController.Fee({startAmount: 0, protocolFeeBps: 200});
        fees[1] = IProtocolFeeController.Fee({startAmount: 100, protocolFeeBps: 100});

        vm.expectRevert(IProtocolFeeController.InvalidInput.selector);
        controller.setProtocolFeePerCurrency(currency, 18, fees, 50);
    }

    // ══════════════════════════════════════════════════════════════════════
    // setProtocolFeePerCurrency — happy paths
    // ══════════════════════════════════════════════════════════════════════

    function test_setProtocolFeePerCurrency_setsOneTier() public {
        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](1);
        fees[0] = IProtocolFeeController.Fee({startAmount: 0, protocolFeeBps: 200});

        controller.setProtocolFeePerCurrency(currency, 18, fees, 0);

        (uint256 feeAmount,) = controller.getProtocolFeeAmount(currency, 50e18);
        assertEq(feeAmount, 50e18 * 200 / BPS);
    }

    function test_setProtocolFeePerCurrency_setsTwoTiers() public {
        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](2);
        fees[0] = IProtocolFeeController.Fee({startAmount: 0, protocolFeeBps: 200});
        fees[1] = IProtocolFeeController.Fee({startAmount: 10, protocolFeeBps: 100});

        controller.setProtocolFeePerCurrency(currency, 18, fees, 0);

        // 30 ETH: 10e18*200/BPS + 20e18*100/BPS = 2e17 + 2e17 = 4e17
        uint256 expected = 10e18 * 200 / BPS + 20e18 * 100 / BPS;
        (uint256 feeAmount,) = controller.getProtocolFeeAmount(currency, 30e18);
        assertEq(feeAmount, expected);
    }

    function test_setProtocolFeePerCurrency_setsThreeTiersAndEmits() public {
        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](3);
        fees[0] = IProtocolFeeController.Fee({startAmount: 0, protocolFeeBps: 200});
        fees[1] = IProtocolFeeController.Fee({startAmount: 10, protocolFeeBps: 100});
        fees[2] = IProtocolFeeController.Fee({startAmount: 50, protocolFeeBps: 50});

        vm.expectEmit(true, true, true, true);
        emit IProtocolFeeController.ProtocolFeePerCurrencyUpdated(currency, 18, fees, 100);
        controller.setProtocolFeePerCurrency(currency, 18, fees, 100);
    }

    function test_setProtocolFeePerCurrency_deletesWhenEmptyFees() public {
        // Set per-currency config
        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](1);
        fees[0] = IProtocolFeeController.Fee({startAmount: 0, protocolFeeBps: 200});
        controller.setProtocolFeePerCurrency(currency, 18, fees, 0);

        // Verify per-currency is active (200 bps, not the global 500 bps)
        (uint256 feeAmount,) = controller.getProtocolFeeAmount(currency, 100e18);
        assertEq(feeAmount, 100e18 * 200 / BPS);

        // Delete per-currency config
        IProtocolFeeController.Fee[] memory emptyFees = new IProtocolFeeController.Fee[](0);
        vm.expectEmit(true, true, true, true);
        emit IProtocolFeeController.ProtocolFeePerCurrencyUpdated(currency, 0, emptyFees, 0);
        controller.setProtocolFeePerCurrency(currency, 0, emptyFees, 0);

        // Verify falls back to global (500 bps)
        (feeAmount,) = controller.getProtocolFeeAmount(currency, 100e18);
        assertEq(feeAmount, 100e18 * 500 / BPS);
    }

    function test_setProtocolFeePerCurrency_allowsZeroCap() public {
        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](2);
        fees[0] = IProtocolFeeController.Fee({startAmount: 0, protocolFeeBps: 200});
        fees[1] = IProtocolFeeController.Fee({startAmount: 10, protocolFeeBps: 100});

        // cap=0 means no cap, should succeed
        controller.setProtocolFeePerCurrency(currency, 18, fees, 0);
    }

    function test_setProtocolFeePerCurrency_allowsMaxScale68() public {
        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](1);
        fees[0] = IProtocolFeeController.Fee({startAmount: 0, protocolFeeBps: 200});

        controller.setProtocolFeePerCurrency(currency, 68, fees, 0);
    }

    // ══════════════════════════════════════════════════════════════════════
    // getProtocolFeeAmount — Config A: Falling fees (design doc style)
    //
    // Tier 1: 0..10 ETH   → 200 bps (2%)
    // Tier 2: 10..50 ETH  → 100 bps (1%)
    // Tier 3: 50..100 ETH → 50 bps  (0.5%)
    // Cap: 100 ETH, Scale: 18
    // ══════════════════════════════════════════════════════════════════════

    function _setupConfigA() internal {
        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](3);
        fees[0] = IProtocolFeeController.Fee({startAmount: 0, protocolFeeBps: 200});
        fees[1] = IProtocolFeeController.Fee({startAmount: 10, protocolFeeBps: 100});
        fees[2] = IProtocolFeeController.Fee({startAmount: 50, protocolFeeBps: 50});
        controller.setProtocolFeePerCurrency(currency, 18, fees, 100);
    }

    function _setupConfigANoCap() internal {
        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](3);
        fees[0] = IProtocolFeeController.Fee({startAmount: 0, protocolFeeBps: 200});
        fees[1] = IProtocolFeeController.Fee({startAmount: 10, protocolFeeBps: 100});
        fees[2] = IProtocolFeeController.Fee({startAmount: 50, protocolFeeBps: 50});
        controller.setProtocolFeePerCurrency(currency, 18, fees, 0);
    }

    function test_getProtocolFeeAmount_zeroAmount() public view {
        (uint256 feeAmount, address feeRecipient) = controller.getProtocolFeeAmount(currency, 0);
        assertEq(feeAmount, 0);
        assertEq(feeRecipient, recipient);
    }

    function test_getProtocolFeeAmount_globalFee_whenNoCurrencyConfig() public view {
        // Global fee = 500 bps (from setUp)
        (uint256 feeAmount,) = controller.getProtocolFeeAmount(currency, 80e18);
        assertEq(feeAmount, 80e18 * 500 / BPS);
    }

    function test_getProtocolFeeAmount_oneTier_simple() public {
        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](1);
        fees[0] = IProtocolFeeController.Fee({startAmount: 0, protocolFeeBps: 200});
        controller.setProtocolFeePerCurrency(currency, 18, fees, 0);

        (uint256 feeAmount,) = controller.getProtocolFeeAmount(currency, 80e18);
        // Single flat tier: 80e18 * 200 / 10000 = 1.6e18 (exact, no rounding needed)
        assertEq(feeAmount, 80e18 * 200 / BPS);
    }

    function test_getProtocolFeeAmount_fallingFees_withinFirstBracket() public {
        _setupConfigA();
        (uint256 feeAmount,) = controller.getProtocolFeeAmount(currency, 5e18);
        // 5 ETH fully in tier 1: 5e18 * 200 / 10000 = 1e17
        assertEq(feeAmount, 5e18 * 200 / BPS);
    }

    function test_getProtocolFeeAmount_fallingFees_exactlyAtTier2Boundary() public {
        _setupConfigA();
        (uint256 feeAmount,) = controller.getProtocolFeeAmount(currency, 10e18);
        // 10 ETH = exactly tier 1 boundary: 10e18 * 200 / 10000 = 2e17
        assertEq(feeAmount, 10e18 * 200 / BPS);
    }

    function test_getProtocolFeeAmount_fallingFees_inSecondBracket() public {
        _setupConfigA();
        (uint256 feeAmount,) = controller.getProtocolFeeAmount(currency, 30e18);
        assertEq(feeAmount, 10e18 * 200 / BPS + 20e18 * 100 / BPS);
    }

    function test_getProtocolFeeAmount_fallingFees_inThirdBracket() public {
        _setupConfigA();
        (uint256 feeAmount,) = controller.getProtocolFeeAmount(currency, 80e18);
        assertEq(feeAmount, 10e18 * 200 / BPS + 40e18 * 100 / BPS + 30e18 * 50 / BPS);
    }

    function test_getProtocolFeeAmount_fallingFees_atCap() public {
        _setupConfigA();
        (uint256 feeAmount,) = controller.getProtocolFeeAmount(currency, 100e18);
        assertEq(feeAmount, 10e18 * 200 / BPS + 40e18 * 100 / BPS + 50e18 * 50 / BPS);
    }

    function test_getProtocolFeeAmount_fallingFees_aboveCap() public {
        _setupConfigA();
        // Fee on first 100e18 only (cap) — same raw fee regardless of query amount
        (uint256 feeAmount,) = controller.getProtocolFeeAmount(currency, 150e18);
        assertEq(feeAmount, 10e18 * 200 / BPS + 40e18 * 100 / BPS + 50e18 * 50 / BPS);
    }

    function test_getProtocolFeeAmount_fallingFees_noCap() public {
        _setupConfigANoCap();
        // Tier 3 extends to full amount (no cap)
        (uint256 feeAmount,) = controller.getProtocolFeeAmount(currency, 150e18);
        assertEq(feeAmount, 10e18 * 200 / BPS + 40e18 * 100 / BPS + 100e18 * 50 / BPS);
    }

    // ══════════════════════════════════════════════════════════════════════
    // getProtocolFeeAmount — Config B: Rising fees
    //
    // Tier 1: 0..20 ETH    → 50 bps  (0.5%)
    // Tier 2: 20..80 ETH   → 200 bps (2%)
    // Tier 3: 80..150 ETH  → 500 bps (5%)
    // Cap: 150 ETH, Scale: 18
    // ══════════════════════════════════════════════════════════════════════

    function _setupConfigB() internal {
        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](3);
        fees[0] = IProtocolFeeController.Fee({startAmount: 0, protocolFeeBps: 50});
        fees[1] = IProtocolFeeController.Fee({startAmount: 20, protocolFeeBps: 200});
        fees[2] = IProtocolFeeController.Fee({startAmount: 80, protocolFeeBps: 500});
        controller.setProtocolFeePerCurrency(currency, 18, fees, 150);
    }

    function _refFeeConfigA(uint256 amount) internal pure returns (uint256) {
        // Config A:
        // [0,10e18): 200 bps
        // [10e18,50e18): 100 bps
        // [50e18,100e18): 50 bps
        // Cap: 100e18
        uint256 capped = amount > 100e18 ? 100e18 : amount;
        uint256 fee;

        uint256 tier1 = capped > 10e18 ? 10e18 : capped;
        fee += tier1 * 200 / BPS;
        if (capped <= 10e18) return fee;

        uint256 tier2Upper = capped > 50e18 ? 50e18 : capped;
        uint256 tier2 = tier2Upper - 10e18;
        fee += tier2 * 100 / BPS;
        if (capped <= 50e18) return fee;

        uint256 tier3 = capped - 50e18;
        fee += tier3 * 50 / BPS;
        return fee;
    }

    function _refFeeConfigB(uint256 amount) internal pure returns (uint256) {
        // Config B:
        // [0,20e18): 50 bps
        // [20e18,80e18): 200 bps
        // [80e18,150e18): 500 bps
        // Cap: 150e18
        uint256 capped = amount > 150e18 ? 150e18 : amount;
        uint256 fee;

        uint256 tier1 = capped > 20e18 ? 20e18 : capped;
        fee += tier1 * 50 / BPS;
        if (capped <= 20e18) return fee;

        uint256 tier2Upper = capped > 80e18 ? 80e18 : capped;
        uint256 tier2 = tier2Upper - 20e18;
        fee += tier2 * 200 / BPS;
        if (capped <= 80e18) return fee;

        uint256 tier3 = capped - 80e18;
        fee += tier3 * 500 / BPS;
        return fee;
    }

    function test_getProtocolFeeAmount_risingFees_withinFirstBracket() public {
        _setupConfigB();
        (uint256 feeAmount,) = controller.getProtocolFeeAmount(currency, 10e18);
        // 10 ETH * 50 / 10000 = 5e16
        assertEq(feeAmount, 10e18 * 50 / BPS);
    }

    function test_getProtocolFeeAmount_risingFees_inSecondBracket() public {
        _setupConfigB();
        (uint256 feeAmount,) = controller.getProtocolFeeAmount(currency, 50e18);
        assertEq(feeAmount, 20e18 * 50 / BPS + 30e18 * 200 / BPS);
    }

    function test_getProtocolFeeAmount_risingFees_inThirdBracket() public {
        _setupConfigB();
        (uint256 feeAmount,) = controller.getProtocolFeeAmount(currency, 120e18);
        assertEq(feeAmount, 20e18 * 50 / BPS + 60e18 * 200 / BPS + 40e18 * 500 / BPS);
    }

    function test_getProtocolFeeAmount_risingFees_aboveCap() public {
        _setupConfigB();
        // Fee on first 150e18 (cap) — same raw fee regardless of query amount
        (uint256 feeAmount,) = controller.getProtocolFeeAmount(currency, 200e18);
        assertEq(feeAmount, 20e18 * 50 / BPS + 60e18 * 200 / BPS + 70e18 * 500 / BPS);
    }

    // ══════════════════════════════════════════════════════════════════════
    // getProtocolFeeAmount — additional edge cases
    // ══════════════════════════════════════════════════════════════════════

    function test_getProtocolFeeAmount_amountOfOne() public view {
        // Global fee = 500 bps. 1 * 500 / 10000 = 0
        (uint256 feeAmount,) = controller.getProtocolFeeAmount(currency, 1);
        assertEq(feeAmount, 0);
    }

    function test_getProtocolFeeAmount_cappedFee_doesNotShrinkAboveCap() public {
        // Regression: old rounding made capped fees shrink toward zero as amount grows.
        // scale=0, 1 tier at 200 bps, cap=100. Capped fee = 100 * 200 / 10000 = 2.
        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](1);
        fees[0] = IProtocolFeeController.Fee({startAmount: 0, protocolFeeBps: 200});
        controller.setProtocolFeePerCurrency(currency, 0, fees, 100);

        // At cap: fee = 2
        (uint256 feeAt100,) = controller.getProtocolFeeAmount(currency, 100);
        assertEq(feeAt100, 2);

        // Above cap: fee must stay at 2 (the plateau), not shrink
        (uint256 feeAt101,) = controller.getProtocolFeeAmount(currency, 101);
        assertEq(feeAt101, 2, "Fee must not shrink above cap");

        // Far above cap: fee must still be 2, not zero
        (uint256 feeAt20001,) = controller.getProtocolFeeAmount(currency, 20_001);
        assertEq(feeAt20001, 2, "Fee must not vanish far above cap");
    }

    function test_getProtocolFeeAmount_capsAmountToPreventOverflow() public view {
        // Global fee = 500 bps. For amounts > type(uint256).max / BPS, the contract
        // caps the amount to prevent silent overflow in assembly mul operations.
        uint256 maxSafe = type(uint256).max / BPS;

        // At the cap boundary: should return the fee on maxSafe
        (uint256 feeAtMax,) = controller.getProtocolFeeAmount(currency, maxSafe);
        assertEq(feeAtMax, maxSafe * 500 / BPS);

        // Above the cap: should return the same fee (amount is capped internally)
        (uint256 feeAboveMax,) = controller.getProtocolFeeAmount(currency, maxSafe + 1);
        assertEq(feeAboveMax, feeAtMax, "Fee must not wrap on overflow amount");

        // type(uint256).max: same capped fee, no revert
        (uint256 feeAtUintMax,) = controller.getProtocolFeeAmount(currency, type(uint256).max);
        assertEq(feeAtUintMax, feeAtMax, "Fee must not wrap on uint256 max");
    }

    function test_getProtocolFeeBps_doesNotRevertOnOverflowAmount() public view {
        // Must not revert even at type(uint256).max — the internal cap prevents overflow.
        // Bps is 0 because the capped fee is negligible relative to type(uint256).max.
        (uint24 bps,) = controller.getProtocolFeeBps(currency, type(uint256).max);
        assertEq(bps, 0);
    }

    function test_getProtocolFeeAmount_maxScale() public {
        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](2);
        fees[0] = IProtocolFeeController.Fee({startAmount: 0, protocolFeeBps: 100});
        fees[1] = IProtocolFeeController.Fee({startAmount: 1, protocolFeeBps: 50});
        controller.setProtocolFeePerCurrency(currency, 68, fees, 0);

        // Tier boundary at 1 * 10^68. Use an amount above it.
        uint256 boundary = 1 * 10 ** 68;
        uint256 amount = 2 * 10 ** 68;
        uint256 expected = boundary * 100 / BPS + boundary * 50 / BPS;

        (uint256 feeAmount,) = controller.getProtocolFeeAmount(currency, amount);
        assertEq(feeAmount, expected);
    }

    function test_getProtocolFeeAmount_perCurrencyOverridesGlobal() public {
        // Global = 500 bps (from setUp)
        // Per-currency = 100 bps flat
        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](1);
        fees[0] = IProtocolFeeController.Fee({startAmount: 0, protocolFeeBps: 100});
        controller.setProtocolFeePerCurrency(currency, 18, fees, 0);

        (uint256 feeAmount,) = controller.getProtocolFeeAmount(currency, 100e18);
        // Should use per-currency (100 bps), not global (500 bps)
        assertEq(feeAmount, 100e18 * 100 / BPS);
    }

    function test_getProtocolFeeAmount_deletedCurrencyFallsBackToGlobal() public {
        // Set per-currency
        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](1);
        fees[0] = IProtocolFeeController.Fee({startAmount: 0, protocolFeeBps: 100});
        controller.setProtocolFeePerCurrency(currency, 18, fees, 0);

        // Delete it
        IProtocolFeeController.Fee[] memory emptyFees = new IProtocolFeeController.Fee[](0);
        controller.setProtocolFeePerCurrency(currency, 0, emptyFees, 0);

        // Should fall back to global (500 bps)
        (uint256 feeAmount,) = controller.getProtocolFeeAmount(currency, 100e18);
        assertEq(feeAmount, 100e18 * 500 / BPS);
    }

    function test_getProtocolFeeAmount_currencyConfigsAreIsolated() public {
        address currencyA = makeAddr("currencyA");
        address currencyB = makeAddr("currencyB");
        uint256 amount = 100e18;

        IProtocolFeeController.Fee[] memory feesA = new IProtocolFeeController.Fee[](1);
        feesA[0] = IProtocolFeeController.Fee({startAmount: 0, protocolFeeBps: 100});
        controller.setProtocolFeePerCurrency(currencyA, 18, feesA, 0);

        IProtocolFeeController.Fee[] memory feesB = new IProtocolFeeController.Fee[](1);
        feesB[0] = IProtocolFeeController.Fee({startAmount: 0, protocolFeeBps: 250});
        controller.setProtocolFeePerCurrency(currencyB, 18, feesB, 0);

        (uint256 feeA,) = controller.getProtocolFeeAmount(currencyA, amount);
        (uint256 feeB,) = controller.getProtocolFeeAmount(currencyB, amount);
        (uint256 feeDefault,) = controller.getProtocolFeeAmount(makeAddr("currencyC"), amount);

        assertEq(feeA, amount * 100 / BPS, "currencyA should use its own fee config");
        assertEq(feeB, amount * 250 / BPS, "currencyB should use its own fee config");
        assertEq(feeDefault, amount * 500 / BPS, "unconfigured currency should use global fee");
    }

    function test_getProtocolFeeAmount_updatesToLatestGlobalRecipient_evenWithCurrencyConfig() public {
        _setupConfigA();
        address newRecipient = makeAddr("newGlobalRecipient");
        controller.setGlobalProtocolFeeSettings(700, newRecipient);

        (, address feeRecipient) = controller.getProtocolFeeAmount(currency, 100e18);
        assertEq(feeRecipient, newRecipient);
    }

    function test_getProtocolFeeAmount_scale0_withCap_plateausAsExpected() public {
        // scale=0 means bracket thresholds are raw integers.
        // Brackets: [0..10) => 10%, [10..20) => 5%, cap at 20.
        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](2);
        fees[0] = IProtocolFeeController.Fee({startAmount: 0, protocolFeeBps: 1000});
        fees[1] = IProtocolFeeController.Fee({startAmount: 10, protocolFeeBps: 500});
        controller.setProtocolFeePerCurrency(currency, 0, fees, 20);

        (uint256 feeAt7,) = controller.getProtocolFeeAmount(currency, 7);
        assertEq(feeAt7, 0, "integer division should floor small values");

        (uint256 feeAt15,) = controller.getProtocolFeeAmount(currency, 15);
        assertEq(feeAt15, (10 * 1000 / BPS) + (5 * 500 / BPS));

        (uint256 feeAt1000,) = controller.getProtocolFeeAmount(currency, 1000);
        assertEq(feeAt1000, (10 * 1000 / BPS) + (10 * 500 / BPS), "fee should plateau at cap");
    }

    // ══════════════════════════════════════════════════════════════════════
    // getProtocolFeeBps
    // ══════════════════════════════════════════════════════════════════════

    function test_getProtocolFeeBps_zeroAmount() public view {
        (uint24 bps, address feeRecipient) = controller.getProtocolFeeBps(currency, 0);
        assertEq(bps, 0);
        assertEq(feeRecipient, recipient);
    }

    function test_getProtocolFeeBps_globalFee() public view {
        (uint24 bps,) = controller.getProtocolFeeBps(currency, 100e18);
        assertEq(bps, 500);
    }

    function test_getProtocolFeeBps_progressive_truncates() public {
        _setupConfigA();
        // 80 ETH: effective bps = floor(7.5e17 * 10000 / 80e18) = 93
        (uint24 bps,) = controller.getProtocolFeeBps(currency, 80e18);
        assertEq(bps, 93);
    }

    function test_getProtocolFeeBps_consistentWithGetProtocolFeeAmount() public {
        _setupConfigA();
        uint256 amount = 80e18;

        (uint24 bps,) = controller.getProtocolFeeBps(currency, amount);
        (uint256 feeAmount,) = controller.getProtocolFeeAmount(currency, amount);

        // bps is a truncated approximation of the raw fee — within 1 bps
        assertEq(bps, uint24(feeAmount * BPS / amount));
        assertGe(feeAmount, uint256(bps) * amount / BPS);
        assertLe(feeAmount, (uint256(bps) + 1) * amount / BPS);
    }

    // ══════════════════════════════════════════════════════════════════════
    // Recipient propagation
    // ══════════════════════════════════════════════════════════════════════

    function test_getProtocolFeeAmount_returnsGlobalRecipient_whenNoCurrencyConfig() public view {
        (, address feeRecipient) = controller.getProtocolFeeAmount(currency, 100e18);
        assertEq(feeRecipient, recipient);
    }

    function test_getProtocolFeeAmount_returnsGlobalRecipient_whenCurrencyConfigExists() public {
        _setupConfigA();
        (, address feeRecipient) = controller.getProtocolFeeAmount(currency, 100e18);
        // Per-currency fees still return the global recipient
        assertEq(feeRecipient, recipient);
    }

    function test_getProtocolFeeBps_returnsGlobalRecipient_onZeroAmount() public view {
        (, address feeRecipient) = controller.getProtocolFeeBps(currency, 0);
        assertEq(feeRecipient, recipient);
    }

    // ══════════════════════════════════════════════════════════════════════
    // Fuzz tests
    // ══════════════════════════════════════════════════════════════════════

    function test_fuzz_setGlobalProtocolFeeSettings_validRange(uint24 bps, address _recipient) public {
        bps = uint24(bound(bps, 0, BPS));
        vm.assume(_recipient != address(0));

        controller.setGlobalProtocolFeeSettings(bps, _recipient);
        (uint24 storedBps, address storedRecipient) = controller.globalProtocolFee();
        assertEq(storedBps, bps);
        assertEq(storedRecipient, _recipient);
    }

    function test_fuzz_getProtocolFeeAmount_lteAmount(uint256 amount) public {
        amount = bound(amount, 1, type(uint128).max);
        _setupConfigA();

        (uint256 feeAmount,) = controller.getProtocolFeeAmount(currency, amount);
        assertLe(feeAmount, amount, "Fee should never exceed amount");
    }

    function test_fuzz_getProtocolFeeAmount_bpsConsistency(uint256 amount) public {
        amount = bound(amount, 1, type(uint128).max);
        _setupConfigA();

        (uint24 bps,) = controller.getProtocolFeeBps(currency, amount);
        (uint256 feeAmount,) = controller.getProtocolFeeAmount(currency, amount);

        // bps is derived from raw fee by truncation — must match
        assertEq(bps, uint24(feeAmount * BPS / amount), "bps must equal feeAmount * BPS / amount");
        // feeAmount is within 1 bps of the reported rate
        assertGe(feeAmount, uint256(bps) * amount / BPS, "feeAmount must be >= bps * amount / BPS");
        assertLe(feeAmount, (uint256(bps) + 1) * amount / BPS, "feeAmount must be <= (bps+1) * amount / BPS");
    }

    function test_fuzz_getProtocolFeeAmount_exactMatch_referenceConfigA(uint256 amount) public {
        amount = bound(amount, 1, type(uint128).max);
        _setupConfigA();

        (uint256 feeAmount,) = controller.getProtocolFeeAmount(currency, amount);
        assertEq(feeAmount, _refFeeConfigA(amount), "progressive fee must match reference model (Config A)");
    }

    function test_fuzz_getProtocolFeeAmount_globalFee_exact(uint256 amount, uint24 bps) public {
        amount = bound(amount, 1, type(uint128).max);
        bps = uint24(bound(bps, 0, BPS));
        address _recipient = makeAddr("fuzzRecipient");

        controller.setGlobalProtocolFeeSettings(bps, _recipient);

        (uint256 feeAmount,) = controller.getProtocolFeeAmount(currency, amount);
        assertEq(feeAmount, amount * bps / BPS, "Global fee must be exact");
    }

    function test_fuzz_setProtocolFeePerCurrency_validInputs(
        uint8 scale,
        uint16 start2,
        uint16 feeBps1,
        uint16 feeBps2,
        uint16 cap
    ) public {
        scale = uint8(bound(scale, 0, 68));
        feeBps1 = uint16(bound(feeBps1, 0, BPS));
        feeBps2 = uint16(bound(feeBps2, 0, BPS));
        start2 = uint16(bound(start2, 1, type(uint16).max)); // must be > 0 (ascending from fees[0].startAmount=0)

        // cap must be > start2 or 0. If start2 is max uint16, no valid cap > start2 exists.
        if (cap != 0 && start2 < type(uint16).max) {
            cap = uint16(bound(cap, start2 + 1, type(uint16).max));
        } else {
            cap = 0; // no cap
        }

        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](2);
        fees[0] = IProtocolFeeController.Fee({startAmount: 0, protocolFeeBps: feeBps1});
        fees[1] = IProtocolFeeController.Fee({startAmount: start2, protocolFeeBps: feeBps2});

        // Should never revert for valid inputs
        controller.setProtocolFeePerCurrency(currency, scale, fees, cap);
    }

    function test_fuzz_getProtocolFeeAmount_bpsConsistency_risingFees(uint256 amount) public {
        amount = bound(amount, 1, type(uint128).max);
        _setupConfigB();

        (uint24 bps,) = controller.getProtocolFeeBps(currency, amount);
        (uint256 feeAmount,) = controller.getProtocolFeeAmount(currency, amount);

        assertEq(bps, uint24(feeAmount * BPS / amount), "bps must equal feeAmount * BPS / amount");
        assertGe(feeAmount, uint256(bps) * amount / BPS, "feeAmount must be >= bps * amount / BPS");
        assertLe(feeAmount, (uint256(bps) + 1) * amount / BPS, "feeAmount must be <= (bps+1) * amount / BPS");
    }

    function test_fuzz_getProtocolFeeAmount_exactMatch_referenceConfigB(uint256 amount) public {
        amount = bound(amount, 1, type(uint128).max);
        _setupConfigB();

        (uint256 feeAmount,) = controller.getProtocolFeeAmount(currency, amount);
        assertEq(feeAmount, _refFeeConfigB(amount), "progressive fee must match reference model (Config B)");
    }
}
