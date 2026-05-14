// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ProtocolFeeController} from "../../src/periphery/ProtocolFeeController.sol";
import {IProtocolFeeController} from "../../src/interfaces/IProtocolFeeController.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Ownable} from "solady/auth/Ownable.sol";

contract ProtocolFeeControllerTest is Test {
    ProtocolFeeController public controller;

    address recipient = makeAddr("recipient");

    function setUp() public {
        controller = new ProtocolFeeController(address(this));
        // Establish a recipient so per-currency tier installs are allowed.
        // Pips stay at 0 by default; per-currency tests configure rates as needed.
        controller.setProtocolFeeRecipient(recipient);
    }

    function test_setProtocolFeeRecipient_revertsWhenNotOwner(address _caller) public {
        vm.assume(_caller != address(this));
        vm.prank(_caller);
        vm.expectRevert(Ownable.Unauthorized.selector);
        controller.setProtocolFeeRecipient(recipient);
    }

    function test_setProtocolFeeRecipient_setsAndEmits(address _recipient) public {
        vm.expectEmit(true, true, true, true);
        emit IProtocolFeeController.ProtocolFeeRecipientUpdated(_recipient);
        controller.setProtocolFeeRecipient(_recipient);
        assertEq(controller.protocolFeeRecipient(), _recipient);
    }

    function test_setProtocolFeeRecipient_acceptsZero() public {
        controller.setProtocolFeeRecipient(address(0));
        assertEq(controller.protocolFeeRecipient(), address(0));
    }

    function test_setGlobalProtocolFeePips_revertsWhenNotOwner(address _caller, uint24 _pips) public {
        vm.assume(_caller != address(this));
        _pips = uint24(bound(_pips, 0, controller.PIPS_DENOMINATOR()));

        vm.prank(_caller);
        vm.expectRevert(Ownable.Unauthorized.selector);
        controller.setGlobalProtocolFeePips(_pips);
    }

    function test_setGlobalProtocolFeePips_revertsWhenPipsExceedsDenominator(uint24 _pips) public {
        _pips = uint24(bound(_pips, controller.PIPS_DENOMINATOR() + 1, type(uint24).max));

        vm.expectRevert(
            abi.encodeWithSelector(IProtocolFeeController.InvalidFeePips.selector, _pips, controller.PIPS_DENOMINATOR())
        );
        controller.setGlobalProtocolFeePips(_pips);
    }

    function test_setGlobalProtocolFeePips_setsAndEmits(uint24 _pips) public {
        _pips = uint24(bound(_pips, 1, controller.PIPS_DENOMINATOR()));

        vm.expectEmit(true, true, true, true);
        emit IProtocolFeeController.GlobalProtocolFeePipsUpdated(_pips);
        controller.setGlobalProtocolFeePips(_pips);

        assertEq(controller.globalProtocolFeePips(), _pips);
    }

    function test_freshDeployment_chargesZeroFeeAndHasNoRecipient(address _currency, uint256 _amount) public {
        ProtocolFeeController fresh = new ProtocolFeeController(address(this));
        assertEq(fresh.getProtocolFeeAmount(_currency, _amount), 0);
        assertEq(fresh.protocolFeeRecipient(), address(0));
    }

    function test_setProtocolFeePerCurrency_revertsWhenNotOwner(address _caller, address _currency) public {
        vm.assume(_caller != address(this));

        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](1);
        fees[0] = IProtocolFeeController.Fee({lowerThreshold: 0, protocolFeePips: 20_000});

        vm.prank(_caller);
        vm.expectRevert(Ownable.Unauthorized.selector);
        controller.setProtocolFeePerCurrency(_currency, fees);
    }

    function test_setProtocolFeePerCurrency_revertsWhenLengthExceedsMaxProtocolFeeTiers(address _currency) public {
        uint256 length = controller.MAX_PROTOCOL_FEE_TIERS() + 1;
        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](length);
        for (uint256 i; i < length; ++i) {
            fees[i] = IProtocolFeeController.Fee({lowerThreshold: int128(uint128(i)), protocolFeePips: 20_000});
        }

        vm.expectRevert(abi.encodeWithSelector(IProtocolFeeController.InvalidFeeLength.selector, length));
        controller.setProtocolFeePerCurrency(_currency, fees);
    }

    function test_setProtocolFeePerCurrency_revertsWhenFeePipsExceedsDenominator(uint24 _pips, address _currency)
        public
    {
        _pips = uint24(bound(_pips, controller.PIPS_DENOMINATOR() + 1, type(uint24).max));

        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](1);
        fees[0] = IProtocolFeeController.Fee({lowerThreshold: 0, protocolFeePips: _pips});

        vm.expectRevert(
            abi.encodeWithSelector(IProtocolFeeController.InvalidFeePips.selector, _pips, controller.PIPS_DENOMINATOR())
        );
        controller.setProtocolFeePerCurrency(_currency, fees);
    }

    function test_setProtocolFeePerCurrency_revertsWhenFirstLowerThresholdIsNonZero(
        int128 _firstThreshold,
        uint24 _pips1,
        uint24 _pips2,
        address _currency
    ) public {
        _firstThreshold = int128(bound(_firstThreshold, 1, type(int128).max));
        _pips1 = uint24(bound(_pips1, 0, controller.PIPS_DENOMINATOR()));
        _pips2 = uint24(bound(_pips2, 0, controller.PIPS_DENOMINATOR()));

        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](2);
        fees[0] = IProtocolFeeController.Fee({lowerThreshold: _firstThreshold, protocolFeePips: _pips1});
        fees[1] = IProtocolFeeController.Fee({lowerThreshold: type(int128).max, protocolFeePips: _pips2});

        vm.expectRevert(
            abi.encodeWithSelector(IProtocolFeeController.FirstThresholdMustBeZero.selector, _firstThreshold)
        );
        controller.setProtocolFeePerCurrency(_currency, fees);
    }

    function test_setProtocolFeePerCurrency_revertsWhenThresholdsNotAscending(
        int128 _threshold1,
        int128 _threshold2,
        address _currency
    ) public {
        _threshold1 = int128(bound(_threshold1, 1, type(int128).max));
        _threshold2 = int128(bound(_threshold2, 0, _threshold1)); // <= threshold1

        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](3);
        fees[0] = IProtocolFeeController.Fee({lowerThreshold: 0, protocolFeePips: 20_000});
        fees[1] = IProtocolFeeController.Fee({lowerThreshold: _threshold1, protocolFeePips: 10_000});
        fees[2] = IProtocolFeeController.Fee({lowerThreshold: _threshold2, protocolFeePips: 5_000});

        vm.expectRevert(
            abi.encodeWithSelector(IProtocolFeeController.ThresholdsNotAscending.selector, _threshold2, _threshold1)
        );
        controller.setProtocolFeePerCurrency(_currency, fees);
    }

    function test_setProtocolFeePerCurrency_setsOneTierAndEmits(uint24 _pips, address _currency) public {
        _pips = uint24(bound(_pips, 0, controller.PIPS_DENOMINATOR()));

        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](1);
        fees[0] = IProtocolFeeController.Fee({lowerThreshold: 0, protocolFeePips: _pips});

        vm.expectEmit(true, true, true, true);
        emit IProtocolFeeController.ProtocolFeePerCurrencyUpdated(_currency, fees);
        controller.setProtocolFeePerCurrency(_currency, fees);

        IProtocolFeeController.Fee[] memory stored = controller.getCurrencyFees(_currency);
        assertEq(stored.length, 1);
        assertEq(stored[0].lowerThreshold, int128(0));
        assertEq(stored[0].protocolFeePips, _pips);
    }

    function test_setProtocolFeePerCurrency_setsValidTwoTiers(
        int128 _threshold,
        uint24 _pips1,
        uint24 _pips2,
        address _currency
    ) public {
        _threshold = int128(bound(_threshold, 1, type(int128).max));
        _pips1 = uint24(bound(_pips1, 0, controller.PIPS_DENOMINATOR()));
        _pips2 = uint24(bound(_pips2, 0, controller.PIPS_DENOMINATOR()));

        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](2);
        fees[0] = IProtocolFeeController.Fee({lowerThreshold: 0, protocolFeePips: _pips1});
        fees[1] = IProtocolFeeController.Fee({lowerThreshold: _threshold, protocolFeePips: _pips2});

        controller.setProtocolFeePerCurrency(_currency, fees);

        IProtocolFeeController.Fee[] memory stored = controller.getCurrencyFees(_currency);
        assertEq(stored.length, 2);
        assertEq(stored[0].lowerThreshold, int128(0));
        assertEq(stored[0].protocolFeePips, _pips1);
        assertEq(stored[1].lowerThreshold, _threshold);
        assertEq(stored[1].protocolFeePips, _pips2);
    }

    function test_setProtocolFeePerCurrency_setsValidThreeTiers(
        int128 _threshold1,
        int128 _threshold2,
        uint24 _pips1,
        uint24 _pips2,
        uint24 _pips3,
        address _currency
    ) public {
        _threshold1 = int128(bound(_threshold1, 1, type(int128).max - 1));
        _threshold2 = int128(bound(_threshold2, _threshold1 + 1, type(int128).max));
        _pips1 = uint24(bound(_pips1, 0, controller.PIPS_DENOMINATOR()));
        _pips2 = uint24(bound(_pips2, 0, controller.PIPS_DENOMINATOR()));
        _pips3 = uint24(bound(_pips3, 0, controller.PIPS_DENOMINATOR()));

        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](3);
        fees[0] = IProtocolFeeController.Fee({lowerThreshold: 0, protocolFeePips: _pips1});
        fees[1] = IProtocolFeeController.Fee({lowerThreshold: _threshold1, protocolFeePips: _pips2});
        fees[2] = IProtocolFeeController.Fee({lowerThreshold: _threshold2, protocolFeePips: _pips3});

        controller.setProtocolFeePerCurrency(_currency, fees);

        IProtocolFeeController.Fee[] memory stored = controller.getCurrencyFees(_currency);
        assertEq(stored.length, 3);
    }

    function test_setProtocolFeePerCurrency_revertsWhenGlobalRecipientUnset(uint24 _pips, address _currency) public {
        _pips = uint24(bound(_pips, 0, controller.PIPS_DENOMINATOR()));

        ProtocolFeeController fresh = new ProtocolFeeController(address(this));

        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](1);
        fees[0] = IProtocolFeeController.Fee({lowerThreshold: 0, protocolFeePips: _pips});

        vm.expectRevert(IProtocolFeeController.RecipientNotSet.selector);
        fresh.setProtocolFeePerCurrency(_currency, fees);
    }

    function test_setProtocolFeePerCurrency_deletesWhenEmptyFees(uint24 _pips, address _currency) public {
        _pips = uint24(bound(_pips, 1, controller.PIPS_DENOMINATOR()));

        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](1);
        fees[0] = IProtocolFeeController.Fee({lowerThreshold: 0, protocolFeePips: _pips});
        controller.setProtocolFeePerCurrency(_currency, fees);
        assertEq(controller.getCurrencyFees(_currency).length, 1);

        IProtocolFeeController.Fee[] memory empty = new IProtocolFeeController.Fee[](0);
        vm.expectEmit(true, true, true, true);
        emit IProtocolFeeController.ProtocolFeePerCurrencyUpdated(_currency, empty);
        controller.setProtocolFeePerCurrency(_currency, empty);
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
        feesA[0] = IProtocolFeeController.Fee({lowerThreshold: 0, protocolFeePips: _pipsA});
        controller.setProtocolFeePerCurrency(_currencyA, feesA);

        IProtocolFeeController.Fee[] memory feesB = new IProtocolFeeController.Fee[](1);
        feesB[0] = IProtocolFeeController.Fee({lowerThreshold: 0, protocolFeePips: _pipsB});
        controller.setProtocolFeePerCurrency(_currencyB, feesB);

        assertEq(controller.getCurrencyFees(_currencyA)[0].protocolFeePips, _pipsA);
        assertEq(controller.getCurrencyFees(_currencyB)[0].protocolFeePips, _pipsB);
    }

    function test_getProtocolFeeAmount_zeroAmountReturnsZero(uint24 _pips, address _currency) public {
        _pips = uint24(bound(_pips, 1, controller.PIPS_DENOMINATOR()));
        controller.setGlobalProtocolFeePips(_pips);

        assertEq(controller.getProtocolFeeAmount(_currency, 0), 0);
        assertEq(controller.protocolFeeRecipient(), recipient);
    }

    function test_getProtocolFeeAmount_globalFee_exact(uint256 _amount, uint24 _pips, address _currency) public {
        _amount = bound(_amount, 1, type(uint128).max);
        _pips = uint24(bound(_pips, 0, controller.PIPS_DENOMINATOR()));
        address _recipient = makeAddr("fuzzRecipient");

        controller.setProtocolFeeRecipient(_recipient);
        controller.setGlobalProtocolFeePips(_pips);

        uint256 feeAmount = controller.getProtocolFeeAmount(_currency, _amount);
        assertEq(feeAmount, _amount * _pips / controller.PIPS_DENOMINATOR());
        assertEq(controller.protocolFeeRecipient(), _recipient);
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

        controller.setGlobalProtocolFeePips(_globalPips);

        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](1);
        fees[0] = IProtocolFeeController.Fee({lowerThreshold: 0, protocolFeePips: _perCurrencyPips});
        controller.setProtocolFeePerCurrency(_currency, fees);
        controller.setProtocolFeePerCurrency(_currency, new IProtocolFeeController.Fee[](0));

        uint256 feeAmount = controller.getProtocolFeeAmount(_currency, _amount);
        assertEq(feeAmount, _amount * _globalPips / controller.PIPS_DENOMINATOR());
    }

    function test_getProtocolFeeAmount_singleTier_flatRate(uint256 _amount, uint24 _pips, address _currency) public {
        _amount = bound(_amount, 1, type(uint128).max);
        _pips = uint24(bound(_pips, 0, controller.PIPS_DENOMINATOR()));

        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](1);
        fees[0] = IProtocolFeeController.Fee({lowerThreshold: 0, protocolFeePips: _pips});
        controller.setProtocolFeePerCurrency(_currency, fees);

        uint256 feeAmount = controller.getProtocolFeeAmount(_currency, _amount);
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

        controller.setGlobalProtocolFeePips(_globalPips);

        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](1);
        fees[0] = IProtocolFeeController.Fee({lowerThreshold: 0, protocolFeePips: _perCurrencyPips});
        controller.setProtocolFeePerCurrency(_currency, fees);

        uint256 feeAmount = controller.getProtocolFeeAmount(_currency, _amount);
        assertEq(feeAmount, _amount * _perCurrencyPips / controller.PIPS_DENOMINATOR());
    }

    /// @dev Reference implementation: computes the expected fee for a two-tier config.
    ///      threshold is the lowerThreshold of the second tier (also the upper edge of the first).
    ///      threshold is int128 to match Fee.lowerThreshold; cast to uint256 inside is safe since
    ///      setProtocolFeePerCurrency rejects negative thresholds.
    function _refFeeTwoTier(uint256 amount, int128 threshold, uint24 pips1, uint24 pips2)
        internal
        view
        returns (uint256)
    {
        uint256 thresholdU = uint256(uint128(threshold));
        uint256 tier1 = amount > thresholdU ? thresholdU : amount;
        uint256 fee = FullMath.mulDiv(tier1, pips1, controller.PIPS_DENOMINATOR());
        if (amount > thresholdU) {
            fee += FullMath.mulDiv(amount - thresholdU, pips2, controller.PIPS_DENOMINATOR());
        }
        return fee;
    }

    /// @dev Reference implementation: computes the expected fee for a three-tier config.
    ///      threshold1 is the lowerThreshold of the second tier, threshold2 of the third.
    ///      Thresholds are int128 to match Fee.lowerThreshold; cast inside is safe (see _refFeeTwoTier).
    function _refFeeThreeTier(
        uint256 amount,
        int128 threshold1,
        int128 threshold2,
        uint24 pips1,
        uint24 pips2,
        uint24 pips3
    ) internal view returns (uint256) {
        uint256 threshold1U = uint256(uint128(threshold1));
        uint256 threshold2U = uint256(uint128(threshold2));
        uint256 fee;
        uint256 tier1 = amount > threshold1U ? threshold1U : amount;
        fee += FullMath.mulDiv(tier1, pips1, controller.PIPS_DENOMINATOR());
        if (amount <= threshold1U) return fee;

        uint256 tier2 = (amount > threshold2U ? threshold2U : amount) - threshold1U;
        fee += FullMath.mulDiv(tier2, pips2, controller.PIPS_DENOMINATOR());
        if (amount <= threshold2U) return fee;

        fee += FullMath.mulDiv(amount - threshold2U, pips3, controller.PIPS_DENOMINATOR());
        return fee;
    }

    function test_getProtocolFeeAmount_twoTiers_matchesReference(
        uint256 _amount,
        int128 _threshold,
        uint24 _pips1,
        uint24 _pips2,
        address _currency
    ) public {
        _amount = bound(_amount, 1, type(uint256).max);
        _threshold = int128(bound(_threshold, 1, type(int128).max));
        _pips1 = uint24(bound(_pips1, 0, controller.PIPS_DENOMINATOR()));
        _pips2 = uint24(bound(_pips2, 0, controller.PIPS_DENOMINATOR()));

        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](2);
        fees[0] = IProtocolFeeController.Fee({lowerThreshold: 0, protocolFeePips: _pips1});
        fees[1] = IProtocolFeeController.Fee({lowerThreshold: _threshold, protocolFeePips: _pips2});
        controller.setProtocolFeePerCurrency(_currency, fees);

        uint256 feeAmount = controller.getProtocolFeeAmount(_currency, _amount);
        assertEq(feeAmount, _refFeeTwoTier(_amount, _threshold, _pips1, _pips2));
    }

    function test_getProtocolFeeAmount_threeTiers_matchesReference(
        uint256 _amount,
        int128 _threshold1,
        int128 _threshold2,
        uint24 _pips1,
        uint24 _pips2,
        uint24 _pips3,
        address _currency
    ) public {
        _amount = bound(_amount, 1, type(uint256).max);
        _threshold1 = int128(bound(_threshold1, 1, type(int128).max - 1));
        _threshold2 = int128(bound(_threshold2, _threshold1 + 1, type(int128).max));
        _pips1 = uint24(bound(_pips1, 0, controller.PIPS_DENOMINATOR()));
        _pips2 = uint24(bound(_pips2, 0, controller.PIPS_DENOMINATOR()));
        _pips3 = uint24(bound(_pips3, 0, controller.PIPS_DENOMINATOR()));

        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](3);
        fees[0] = IProtocolFeeController.Fee({lowerThreshold: 0, protocolFeePips: _pips1});
        fees[1] = IProtocolFeeController.Fee({lowerThreshold: _threshold1, protocolFeePips: _pips2});
        fees[2] = IProtocolFeeController.Fee({lowerThreshold: _threshold2, protocolFeePips: _pips3});
        controller.setProtocolFeePerCurrency(_currency, fees);

        uint256 feeAmount = controller.getProtocolFeeAmount(_currency, _amount);
        assertEq(feeAmount, _refFeeThreeTier(_amount, _threshold1, _threshold2, _pips1, _pips2, _pips3));
    }

    function test_getProtocolFeeAmount_neverExceedsAmount(uint256 _amount, uint24 _pips, address _currency) public {
        _amount = bound(_amount, 1, type(uint128).max);
        _pips = uint24(bound(_pips, 0, controller.PIPS_DENOMINATOR()));

        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](1);
        fees[0] = IProtocolFeeController.Fee({lowerThreshold: 0, protocolFeePips: _pips});
        controller.setProtocolFeePerCurrency(_currency, fees);

        uint256 feeAmount = controller.getProtocolFeeAmount(_currency, _amount);
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

        controller.setProtocolFeeRecipient(_recipient);
        controller.setGlobalProtocolFeePips(_pips);

        // With per-currency config
        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](1);
        fees[0] = IProtocolFeeController.Fee({lowerThreshold: 0, protocolFeePips: 10_000});
        controller.setProtocolFeePerCurrency(_currency, fees);

        controller.getProtocolFeeAmount(_currency, _amount); // exercise the path
        assertEq(controller.protocolFeeRecipient(), _recipient);
    }

    function test_getProtocolFeeAmount_handlesLargeAmountsWithoutCapping(uint24 _pips, address _currency) public {
        _pips = uint24(bound(_pips, 1, controller.PIPS_DENOMINATOR()));
        controller.setGlobalProtocolFeePips(_pips);

        uint256 feeAmount = controller.getProtocolFeeAmount(_currency, type(uint256).max);

        assertEq(feeAmount, FullMath.mulDiv(type(uint256).max, _pips, controller.PIPS_DENOMINATOR()));
    }

    function test_getProtocolFeeAmount_zeroPipsLastTier_capsTheFee(
        uint256 _amount,
        int128 _threshold,
        uint24 _pips,
        address _currency
    ) public {
        _threshold = int128(bound(_threshold, 1, type(int128).max));
        _pips = uint24(bound(_pips, 1, controller.PIPS_DENOMINATOR()));
        uint256 thresholdU = uint256(uint128(_threshold));
        _amount = bound(_amount, thresholdU + 1, type(uint256).max);

        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](2);
        fees[0] = IProtocolFeeController.Fee({lowerThreshold: 0, protocolFeePips: _pips});
        fees[1] = IProtocolFeeController.Fee({lowerThreshold: _threshold, protocolFeePips: 0});

        controller.setProtocolFeePerCurrency(_currency, fees);

        uint256 feeAtThreshold = thresholdU * _pips / controller.PIPS_DENOMINATOR();

        uint256 feeAmount = controller.getProtocolFeeAmount(_currency, _amount);
        assertEq(feeAmount, feeAtThreshold);
    }
}
