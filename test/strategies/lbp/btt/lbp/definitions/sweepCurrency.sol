// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BttBase} from "../BttBase.sol";
import {ILBPStrategyBase} from "src/interfaces/ILBPStrategyBase.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {FuzzConstructorParameters} from "../BttBase.sol";

// Tests have to be namespaced since it would conflict with the SweepTokenTest
abstract contract SweepCurrencyTest is BttBase {
    function test_SweepCurrency_WhenBlockNumberLTSweepBlock(
        FuzzConstructorParameters memory _parameters,
        uint64 _blockNumber
    ) public {
        // it reverts with {SweepNotAllowed}

        _parameters = _toValidConstructorParameters(_parameters);
        _deployMockToken(_parameters.totalSupply);
        _deployMockCurrency(_parameters.totalSupply);

        _deployStrategy(_parameters);

        vm.assume(_blockNumber < _parameters.migratorParams.sweepBlock);
        vm.roll(_blockNumber);

        vm.expectRevert(
            abi.encodeWithSelector(
                ILBPStrategyBase.SweepNotAllowed.selector, _parameters.migratorParams.sweepBlock, _blockNumber
            )
        );
        lbp.sweepCurrency();
    }

    modifier sweepCurrency_whenBlockNumberIsGTESweepBlock() {
        _;
    }

    function test_SweepCurrency_WhenMsgSenderIsNotOperator(
        FuzzConstructorParameters memory _parameters,
        uint64 _blockNumber,
        address _caller,
        bool _useNativeCurrency
    ) public sweepCurrency_whenBlockNumberIsGTESweepBlock {
        // it reverts with {NotOperator}

        _parameters = _toValidConstructorParameters(_parameters, _useNativeCurrency);

        _deployMockToken(_parameters.totalSupply);
        _deployMockCurrency(_parameters.totalSupply);

        vm.assume(_caller != _parameters.migratorParams.operator);

        _deployStrategy(_parameters);

        vm.assume(_blockNumber >= _parameters.migratorParams.sweepBlock);
        vm.roll(_blockNumber);

        vm.prank(_caller);
        vm.expectRevert(
            abi.encodeWithSelector(ILBPStrategyBase.NotOperator.selector, _caller, _parameters.migratorParams.operator)
        );
        lbp.sweepCurrency();
    }

    modifier sweepCurrency_whenMsgSenderIsOperator() {
        _;
    }

    function test_SweepCurrency_WhenCurrencyBalanceIsZero(
        FuzzConstructorParameters memory _parameters,
        uint64 _blockNumber,
        bool _useNativeCurrency
    ) public sweepCurrency_whenMsgSenderIsOperator {
        // it does not sweep the currency

        _parameters = _toValidConstructorParameters(_parameters, _useNativeCurrency);
        _deployMockToken(_parameters.totalSupply);
        _deployMockCurrency(_parameters.totalSupply);

        _deployStrategy(_parameters);

        vm.assume(_blockNumber >= _parameters.migratorParams.sweepBlock);
        vm.roll(_blockNumber);

        uint256 operatorCurrencyBalanceBefore =
            Currency.wrap(address(_parameters.migratorParams.currency)).balanceOf(_parameters.migratorParams.operator);
        vm.prank(_parameters.migratorParams.operator);
        lbp.sweepCurrency();
        uint256 operatorCurrencyBalanceAfter =
            Currency.wrap(address(_parameters.migratorParams.currency)).balanceOf(_parameters.migratorParams.operator);
        assertEq(
            operatorCurrencyBalanceAfter, operatorCurrencyBalanceBefore, "Operator currency balance should not change"
        );
    }

    modifier sweepCurrency_whenCurrencyBalanceIsGreaterThanZero() {
        _;
    }

    function test_SweepCurrency_WhenCurrencyBalanceIsGreaterThanZero(
        FuzzConstructorParameters memory _parameters,
        uint64 _blockNumber,
        uint256 _amount,
        bool _useNativeCurrency
    ) public sweepCurrency_whenCurrencyBalanceIsGreaterThanZero {
        // it sweeps the currency
        // it emits {CurrencySwept}

        vm.assume(_amount > 0);

        _parameters = _toValidConstructorParameters(_parameters, _useNativeCurrency);
        _deployMockToken(_parameters.totalSupply);
        _deployMockCurrency(_parameters.totalSupply);

        _deployStrategy(_parameters);

        vm.assume(_blockNumber >= _parameters.migratorParams.sweepBlock);
        vm.roll(_blockNumber);

        if (_useNativeCurrency) {
            vm.deal(address(lbp), _amount);
        } else {
            deal(address(_parameters.migratorParams.currency), address(lbp), _amount);
        }

        vm.prank(_parameters.migratorParams.operator);
        vm.expectEmit(true, true, true, true);
        emit ILBPStrategyBase.CurrencySwept(_parameters.migratorParams.operator, _amount);
        lbp.sweepCurrency();
    }
}
