// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ProtocolFeeController} from "../../src/periphery/ProtocolFeeController.sol";
import {IProtocolFeeController} from "../../src/interfaces/IProtocolFeeController.sol";
import {Ownable} from "solady/auth/Ownable.sol";

contract ProtocolFeeControllerTest is Test {
    ProtocolFeeController public controller;

    address recipient = makeAddr("recipient");

    function setUp() public {
        controller = new ProtocolFeeController(address(this));
    }

    function test_setGlobalProtocolFeeSettings_revertsWhenNotOwner(address _caller, uint24 _pips) public {
        vm.assume(_caller != address(this));
        _pips = uint24(bound(_pips, 0, controller.PIPS_DENOMINATOR()));

        vm.prank(_caller);
        vm.expectRevert(Ownable.Unauthorized.selector);
        controller.setGlobalProtocolFeeSettings(_pips, recipient);
    }

    function test_setGlobalProtocolFeeSettings_revertsWhenPipsExceedsDenominator(uint24 _pips) public {
        _pips = uint24(bound(_pips, controller.PIPS_DENOMINATOR() + 1, type(uint24).max));

        vm.expectRevert(
            abi.encodeWithSelector(IProtocolFeeController.InvalidFeePips.selector, _pips, controller.PIPS_DENOMINATOR())
        );
        controller.setGlobalProtocolFeeSettings(_pips, recipient);
    }

    function test_setGlobalProtocolFeeSettings_revertsWhenRecipientIsZeroAndPipsNonZero(uint24 _pips) public {
        _pips = uint24(bound(_pips, 1, controller.PIPS_DENOMINATOR()));

        vm.expectRevert(IProtocolFeeController.InvalidInput.selector);
        controller.setGlobalProtocolFeeSettings(_pips, address(0));
    }

    function test_setGlobalProtocolFeeSettings_allowsZeroRecipientWhenPipsZero() public {
        controller.setGlobalProtocolFeeSettings(0, address(0));
        (uint24 pips, address r) = controller.globalProtocolFee();
        assertEq(pips, 0);
        assertEq(r, address(0));
    }

    function test_setGlobalProtocolFeeSettings_defaultStateIsOff(address _currency) public {
        ProtocolFeeController fresh = new ProtocolFeeController(address(this));
        (uint256 feeAmount, address feeRecipient) = fresh.getProtocolFeeAmount(_currency, 100e18);
        assertEq(feeAmount, 0);
        assertEq(feeRecipient, address(0));
    }

    function test_setGlobalProtocolFeeSettings_setsAndEmits(uint24 _pips, address _recipient) public {
        _pips = uint24(bound(_pips, 1, controller.PIPS_DENOMINATOR()));
        vm.assume(_recipient != address(0));

        vm.expectEmit(true, true, true, true);
        emit IProtocolFeeController.GlobalProtocolFeeSettingsUpdated(_pips, _recipient);
        controller.setGlobalProtocolFeeSettings(_pips, _recipient);

        (uint24 storedPips, address storedRecipient) = controller.globalProtocolFee();
        assertEq(storedPips, _pips);
        assertEq(storedRecipient, _recipient);
    }

    function test_setProtocolFeePerCurrency_revertsWhenNotOwner(address _caller, address _currency) public {
        vm.assume(_caller != address(this));

        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](1);
        fees[0] = IProtocolFeeController.Fee({threshold: 0, protocolFeePips: 20_000});

        vm.prank(_caller);
        vm.expectRevert(Ownable.Unauthorized.selector);
        controller.setProtocolFeePerCurrency(_currency, fees);
    }

    function test_setProtocolFeePerCurrency_revertsWhenLengthExceedsMax(address _currency) public {
        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](4);
        fees[0] = IProtocolFeeController.Fee({threshold: 10e18, protocolFeePips: 50_000});
        fees[1] = IProtocolFeeController.Fee({threshold: 20e18, protocolFeePips: 40_000});
        fees[2] = IProtocolFeeController.Fee({threshold: 30e18, protocolFeePips: 30_000});
        fees[3] = IProtocolFeeController.Fee({threshold: 0, protocolFeePips: 20_000});

        vm.expectRevert(abi.encodeWithSelector(IProtocolFeeController.InvalidFeeLength.selector, 4));
        controller.setProtocolFeePerCurrency(_currency, fees);
    }

    function test_setProtocolFeePerCurrency_revertsWhenFeePipsExceedsDenominator(uint24 _pips, address _currency)
        public
    {
        _pips = uint24(bound(_pips, controller.PIPS_DENOMINATOR() + 1, type(uint24).max));

        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](1);
        fees[0] = IProtocolFeeController.Fee({threshold: 0, protocolFeePips: _pips});

        vm.expectRevert(
            abi.encodeWithSelector(IProtocolFeeController.InvalidFeePips.selector, _pips, controller.PIPS_DENOMINATOR())
        );
        controller.setProtocolFeePerCurrency(_currency, fees);
    }

    function test_setProtocolFeePerCurrency_revertsWhenNonLastThresholdIsZero(
        uint24 _pips1,
        uint24 _pips2,
        address _currency
    ) public {
        _pips1 = uint24(bound(_pips1, 0, controller.PIPS_DENOMINATOR()));
        _pips2 = uint24(bound(_pips2, 0, controller.PIPS_DENOMINATOR()));

        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](2);
        fees[0] = IProtocolFeeController.Fee({threshold: 0, protocolFeePips: _pips1});
        fees[1] = IProtocolFeeController.Fee({threshold: 0, protocolFeePips: _pips2});

        vm.expectRevert(IProtocolFeeController.InvalidInput.selector);
        controller.setProtocolFeePerCurrency(_currency, fees);
    }

    function test_setProtocolFeePerCurrency_revertsWhenThresholdsNotAscending(
        uint128 _threshold1,
        uint128 _threshold2,
        address _currency
    ) public {
        _threshold1 = uint128(bound(_threshold1, 1, type(uint128).max));
        _threshold2 = uint128(bound(_threshold2, 1, _threshold1)); // <= threshold1

        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](3);
        fees[0] = IProtocolFeeController.Fee({threshold: _threshold1, protocolFeePips: 20_000});
        fees[1] = IProtocolFeeController.Fee({threshold: _threshold2, protocolFeePips: 10_000});
        fees[2] = IProtocolFeeController.Fee({threshold: 0, protocolFeePips: 5_000});

        vm.expectRevert(IProtocolFeeController.InvalidInput.selector);
        controller.setProtocolFeePerCurrency(_currency, fees);
    }

    function test_setProtocolFeePerCurrency_setsOneTierAndEmits(uint24 _pips, address _currency) public {
        _pips = uint24(bound(_pips, 0, controller.PIPS_DENOMINATOR()));

        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](1);
        fees[0] = IProtocolFeeController.Fee({threshold: 0, protocolFeePips: _pips});

        vm.expectEmit(true, true, true, true);
        emit IProtocolFeeController.ProtocolFeePerCurrencyUpdated(_currency, fees);
        controller.setProtocolFeePerCurrency(_currency, fees);

        IProtocolFeeController.Fee[] memory stored = controller.getCurrencyFees(_currency);
        assertEq(stored.length, 1);
        assertEq(stored[0].protocolFeePips, _pips);
    }

    function test_setProtocolFeePerCurrency_setsValidTwoTiers(
        uint128 _threshold,
        uint24 _pips1,
        uint24 _pips2,
        address _currency
    ) public {
        _threshold = uint128(bound(_threshold, 1, type(uint128).max));
        _pips1 = uint24(bound(_pips1, 0, controller.PIPS_DENOMINATOR()));
        _pips2 = uint24(bound(_pips2, 0, controller.PIPS_DENOMINATOR()));

        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](2);
        fees[0] = IProtocolFeeController.Fee({threshold: _threshold, protocolFeePips: _pips1});
        fees[1] = IProtocolFeeController.Fee({threshold: 0, protocolFeePips: _pips2});

        controller.setProtocolFeePerCurrency(_currency, fees);

        IProtocolFeeController.Fee[] memory stored = controller.getCurrencyFees(_currency);
        assertEq(stored.length, 2);
        assertEq(stored[0].threshold, _threshold);
        assertEq(stored[0].protocolFeePips, _pips1);
        assertEq(stored[1].protocolFeePips, _pips2);
    }

    function test_setProtocolFeePerCurrency_setsValidThreeTiers(
        uint128 _threshold1,
        uint128 _threshold2,
        uint24 _pips1,
        uint24 _pips2,
        uint24 _pips3,
        address _currency
    ) public {
        _threshold1 = uint128(bound(_threshold1, 1, type(uint128).max - 1));
        _threshold2 = uint128(bound(_threshold2, _threshold1 + 1, type(uint128).max));
        _pips1 = uint24(bound(_pips1, 0, controller.PIPS_DENOMINATOR()));
        _pips2 = uint24(bound(_pips2, 0, controller.PIPS_DENOMINATOR()));
        _pips3 = uint24(bound(_pips3, 0, controller.PIPS_DENOMINATOR()));

        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](3);
        fees[0] = IProtocolFeeController.Fee({threshold: _threshold1, protocolFeePips: _pips1});
        fees[1] = IProtocolFeeController.Fee({threshold: _threshold2, protocolFeePips: _pips2});
        fees[2] = IProtocolFeeController.Fee({threshold: 0, protocolFeePips: _pips3});

        controller.setProtocolFeePerCurrency(_currency, fees);

        IProtocolFeeController.Fee[] memory stored = controller.getCurrencyFees(_currency);
        assertEq(stored.length, 3);
    }

    function test_setProtocolFeePerCurrency_deletesWhenEmptyFees(uint24 _pips, address _currency) public {
        _pips = uint24(bound(_pips, 1, controller.PIPS_DENOMINATOR()));

        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](1);
        fees[0] = IProtocolFeeController.Fee({threshold: 0, protocolFeePips: _pips});
        controller.setProtocolFeePerCurrency(_currency, fees);
        assertEq(controller.getCurrencyFees(_currency).length, 1);

        controller.setProtocolFeePerCurrency(_currency, new IProtocolFeeController.Fee[](0));
        assertEq(controller.getCurrencyFees(_currency).length, 0);
    }

    function test_setProtocolFeePerCurrency_currencyConfigsAreIsolated(
        uint24 _pipsA,
        uint24 _pipsB,
        address _currencyA,
        address _currencyB
    ) public {
        vm.assume(_currencyA != _currencyB);
        _pipsA = uint24(bound(_pipsA, 0, controller.PIPS_DENOMINATOR()));
        _pipsB = uint24(bound(_pipsB, 0, controller.PIPS_DENOMINATOR()));

        IProtocolFeeController.Fee[] memory feesA = new IProtocolFeeController.Fee[](1);
        feesA[0] = IProtocolFeeController.Fee({threshold: 0, protocolFeePips: _pipsA});
        controller.setProtocolFeePerCurrency(_currencyA, feesA);

        IProtocolFeeController.Fee[] memory feesB = new IProtocolFeeController.Fee[](1);
        feesB[0] = IProtocolFeeController.Fee({threshold: 0, protocolFeePips: _pipsB});
        controller.setProtocolFeePerCurrency(_currencyB, feesB);

        assertEq(controller.getCurrencyFees(_currencyA)[0].protocolFeePips, _pipsA);
        assertEq(controller.getCurrencyFees(_currencyB)[0].protocolFeePips, _pipsB);
    }

    function test_getProtocolFeeAmount_zeroAmountReturnsZero(uint24 _pips, address _currency) public {
        _pips = uint24(bound(_pips, 1, controller.PIPS_DENOMINATOR()));
        controller.setGlobalProtocolFeeSettings(_pips, recipient);

        (uint256 feeAmount, address feeRecipient) = controller.getProtocolFeeAmount(_currency, 0);
        assertEq(feeAmount, 0);
        assertEq(feeRecipient, recipient);
    }

    function test_getProtocolFeeAmount_globalFee_exact(uint256 _amount, uint24 _pips, address _currency) public {
        _amount = bound(_amount, 1, type(uint128).max);
        _pips = uint24(bound(_pips, 0, controller.PIPS_DENOMINATOR()));
        address _recipient = makeAddr("fuzzRecipient");

        controller.setGlobalProtocolFeeSettings(_pips, _recipient);

        (uint256 feeAmount, address feeRecipient) = controller.getProtocolFeeAmount(_currency, _amount);
        assertEq(feeAmount, _amount * _pips / controller.PIPS_DENOMINATOR());
        assertEq(feeRecipient, _recipient);
    }

    function test_getProtocolFeeAmount_deletedCurrencyFallsBackToGlobal(
        uint256 _amount,
        uint24 _globalPips,
        uint24 _perCurrencyPips,
        address _currency
    ) public {
        _amount = bound(_amount, 1, type(uint128).max);
        _globalPips = uint24(bound(_globalPips, 1, controller.PIPS_DENOMINATOR()));
        _perCurrencyPips = uint24(bound(_perCurrencyPips, 0, controller.PIPS_DENOMINATOR()));

        controller.setGlobalProtocolFeeSettings(_globalPips, recipient);

        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](1);
        fees[0] = IProtocolFeeController.Fee({threshold: 0, protocolFeePips: _perCurrencyPips});
        controller.setProtocolFeePerCurrency(_currency, fees);
        controller.setProtocolFeePerCurrency(_currency, new IProtocolFeeController.Fee[](0));

        (uint256 feeAmount,) = controller.getProtocolFeeAmount(_currency, _amount);
        assertEq(feeAmount, _amount * _globalPips / controller.PIPS_DENOMINATOR());
    }

    function test_getProtocolFeeAmount_singleTier_flatRate(uint256 _amount, uint24 _pips, address _currency) public {
        _amount = bound(_amount, 1, type(uint128).max);
        _pips = uint24(bound(_pips, 0, controller.PIPS_DENOMINATOR()));

        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](1);
        fees[0] = IProtocolFeeController.Fee({threshold: 0, protocolFeePips: _pips});
        controller.setProtocolFeePerCurrency(_currency, fees);

        (uint256 feeAmount,) = controller.getProtocolFeeAmount(_currency, _amount);
        assertEq(feeAmount, _amount * _pips / controller.PIPS_DENOMINATOR());
    }

    function test_getProtocolFeeAmount_singleTier_overridesGlobal(
        uint256 _amount,
        uint24 _globalPips,
        uint24 _perCurrencyPips,
        address _currency
    ) public {
        _amount = bound(_amount, 1, type(uint128).max);
        _globalPips = uint24(bound(_globalPips, 1, controller.PIPS_DENOMINATOR()));
        _perCurrencyPips = uint24(bound(_perCurrencyPips, 0, controller.PIPS_DENOMINATOR()));

        controller.setGlobalProtocolFeeSettings(_globalPips, recipient);

        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](1);
        fees[0] = IProtocolFeeController.Fee({threshold: 0, protocolFeePips: _perCurrencyPips});
        controller.setProtocolFeePerCurrency(_currency, fees);

        (uint256 feeAmount,) = controller.getProtocolFeeAmount(_currency, _amount);
        assertEq(feeAmount, _amount * _perCurrencyPips / controller.PIPS_DENOMINATOR());
    }

    /// @dev Reference implementation: computes the expected fee for a two-tier config
    function _refFeeTwoTier(uint256 amount, uint128 threshold, uint24 pips1, uint24 pips2)
        internal
        pure
        returns (uint256)
    {
        uint256 tier1 = amount > threshold ? threshold : amount;
        uint256 fee = tier1 * pips1 / 1_000_000;
        if (amount > threshold) {
            fee += (amount - threshold) * pips2 / 1_000_000;
        }
        return fee;
    }

    /// @dev Reference implementation: computes the expected fee for a three-tier config
    function _refFeeThreeTier(
        uint256 amount,
        uint128 threshold1,
        uint128 threshold2,
        uint24 pips1,
        uint24 pips2,
        uint24 pips3
    ) internal pure returns (uint256) {
        uint256 fee;
        uint256 tier1 = amount > threshold1 ? threshold1 : amount;
        fee += tier1 * pips1 / 1_000_000;
        if (amount <= threshold1) return fee;

        uint256 tier2 = (amount > threshold2 ? threshold2 : amount) - threshold1;
        fee += tier2 * pips2 / 1_000_000;
        if (amount <= threshold2) return fee;

        fee += (amount - threshold2) * pips3 / 1_000_000;
        return fee;
    }

    function test_getProtocolFeeAmount_twoTiers_matchesReference(
        uint256 _amount,
        uint128 _threshold,
        uint24 _pips1,
        uint24 _pips2,
        address _currency
    ) public {
        _amount = bound(_amount, 1, type(uint128).max);
        _threshold = uint128(bound(_threshold, 1, type(uint128).max));
        _pips1 = uint24(bound(_pips1, 0, controller.PIPS_DENOMINATOR()));
        _pips2 = uint24(bound(_pips2, 0, controller.PIPS_DENOMINATOR()));

        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](2);
        fees[0] = IProtocolFeeController.Fee({threshold: _threshold, protocolFeePips: _pips1});
        fees[1] = IProtocolFeeController.Fee({threshold: 0, protocolFeePips: _pips2});
        controller.setProtocolFeePerCurrency(_currency, fees);

        (uint256 feeAmount,) = controller.getProtocolFeeAmount(_currency, _amount);
        assertEq(feeAmount, _refFeeTwoTier(_amount, _threshold, _pips1, _pips2));
    }

    function test_getProtocolFeeAmount_threeTiers_matchesReference(
        uint256 _amount,
        uint128 _threshold1,
        uint128 _threshold2,
        uint24 _pips1,
        uint24 _pips2,
        uint24 _pips3,
        address _currency
    ) public {
        _amount = bound(_amount, 1, type(uint128).max);
        _threshold1 = uint128(bound(_threshold1, 1, type(uint128).max - 1));
        _threshold2 = uint128(bound(_threshold2, _threshold1 + 1, type(uint128).max));
        _pips1 = uint24(bound(_pips1, 0, controller.PIPS_DENOMINATOR()));
        _pips2 = uint24(bound(_pips2, 0, controller.PIPS_DENOMINATOR()));
        _pips3 = uint24(bound(_pips3, 0, controller.PIPS_DENOMINATOR()));

        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](3);
        fees[0] = IProtocolFeeController.Fee({threshold: _threshold1, protocolFeePips: _pips1});
        fees[1] = IProtocolFeeController.Fee({threshold: _threshold2, protocolFeePips: _pips2});
        fees[2] = IProtocolFeeController.Fee({threshold: 0, protocolFeePips: _pips3});
        controller.setProtocolFeePerCurrency(_currency, fees);

        (uint256 feeAmount,) = controller.getProtocolFeeAmount(_currency, _amount);
        assertEq(feeAmount, _refFeeThreeTier(_amount, _threshold1, _threshold2, _pips1, _pips2, _pips3));
    }

    function test_getProtocolFeeAmount_neverExceedsAmount(uint256 _amount, uint24 _pips, address _currency) public {
        _amount = bound(_amount, 1, type(uint128).max);
        _pips = uint24(bound(_pips, 0, controller.PIPS_DENOMINATOR()));

        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](1);
        fees[0] = IProtocolFeeController.Fee({threshold: 0, protocolFeePips: _pips});
        controller.setProtocolFeePerCurrency(_currency, fees);

        (uint256 feeAmount,) = controller.getProtocolFeeAmount(_currency, _amount);
        assertLe(feeAmount, _amount);
    }

    function test_getProtocolFeeAmount_alwaysReturnsGlobalRecipient(
        uint24 _pips,
        address _recipient,
        uint256 _amount,
        address _currency
    ) public {
        _pips = uint24(bound(_pips, 1, controller.PIPS_DENOMINATOR()));
        vm.assume(_recipient != address(0));
        _amount = bound(_amount, 1, type(uint128).max);

        controller.setGlobalProtocolFeeSettings(_pips, _recipient);

        // With per-currency config
        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](1);
        fees[0] = IProtocolFeeController.Fee({threshold: 0, protocolFeePips: 10_000});
        controller.setProtocolFeePerCurrency(_currency, fees);

        (, address feeRecipient) = controller.getProtocolFeeAmount(_currency, _amount);
        assertEq(feeRecipient, _recipient);
    }

    function test_getProtocolFeeAmount_capsAmountToPreventOverflow(uint24 _pips, address _currency) public {
        _pips = uint24(bound(_pips, 1, controller.PIPS_DENOMINATOR()));
        controller.setGlobalProtocolFeeSettings(_pips, recipient);
        uint256 maxSafe = type(uint256).max / controller.PIPS_DENOMINATOR();

        (uint256 feeAtMax,) = controller.getProtocolFeeAmount(_currency, maxSafe);
        (uint256 feeAboveMax,) = controller.getProtocolFeeAmount(_currency, maxSafe + 1);
        (uint256 feeAtUintMax,) = controller.getProtocolFeeAmount(_currency, type(uint256).max);

        assertEq(feeAboveMax, feeAtMax);
        assertEq(feeAtUintMax, feeAtMax);
    }

    function test_getProtocolFeeAmount_zeroPipsLastTier_capsTheFee(
        uint256 _amount,
        uint128 _threshold,
        uint24 _pips,
        address _currency
    ) public {
        _threshold = uint128(bound(_threshold, 1, type(uint64).max));
        _pips = uint24(bound(_pips, 1, controller.PIPS_DENOMINATOR()));
        _amount = bound(_amount, uint256(_threshold) + 1, type(uint128).max);

        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](2);
        fees[0] = IProtocolFeeController.Fee({threshold: _threshold, protocolFeePips: _pips});
        fees[1] = IProtocolFeeController.Fee({threshold: 0, protocolFeePips: 0});

        controller.setProtocolFeePerCurrency(_currency, fees);

        uint256 feeAtThreshold = uint256(_threshold) * _pips / controller.PIPS_DENOMINATOR();

        (uint256 feeAmount,) = controller.getProtocolFeeAmount(_currency, _amount);
        assertEq(feeAmount, feeAtThreshold);
    }
}
