// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MigrateBttBase, FuzzConstructorParameters} from "./MigrateBttBase.sol";
import {ILBPStrategyBase} from "src/interfaces/ILBPStrategyBase.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

abstract contract ValidateMigrationTest is MigrateBttBase {
    function test_WhenBlockNumberIsLTMigrationBlock(FuzzConstructorParameters memory _parameters, uint64 _blockNumber)
        public
        handleMigrate
    {
        _parameters = _toValidConstructorParameters(_parameters);
        _deployMockToken(_parameters.totalSupply);

        _deployStrategy(_parameters);

        vm.assume(_blockNumber < _parameters.migratorParams.migrationBlock);
        vm.roll(_blockNumber);

        $parameters = _parameters;
        $revertData = abi.encodeWithSelector(
            ILBPStrategyBase.MigrationNotAllowed.selector, _parameters.migratorParams.migrationBlock, _blockNumber
        );
    }

    modifier whenBlockNumberIsGTEMigrationBlock() {
        _;
    }

    function test_WhenCurrencyAmountIsOverUint128Max(
        FuzzConstructorParameters memory _parameters,
        uint64 _blockNumber,
        uint256 _currencyAmount,
        bool _useNativeCurrency
    ) public whenBlockNumberIsGTEMigrationBlock handleMigrate {
        // it reverts with {CurrencyAmountTooHigh}

        $parameters = _toValidConstructorParameters(_parameters, _useNativeCurrency);
        _deployMockToken($parameters.totalSupply);

        _deployStrategy($parameters);

        vm.assume(_blockNumber >= $parameters.migratorParams.migrationBlock);
        vm.roll(_blockNumber);

        _currencyAmount = _bound(_currencyAmount, uint256(type(uint128).max) + 1, type(uint256).max);

        mockAuctionCheckpoint(lbp);
        mockCurrencyRaised(lbp, _currencyAmount);

        $parameters = _parameters;
        $revertData =
            abi.encodeWithSelector(ILBPStrategyBase.CurrencyAmountTooHigh.selector, _currencyAmount, type(uint128).max);
    }

    modifier whenCurrencyAmountIsZero() {
        _;
    }

    function test_WhenCurrencyAmountIsZero(FuzzConstructorParameters memory _parameters, uint64 _blockNumber)
        public
        whenCurrencyAmountIsZero
        handleMigrate
    {
        // it reverts with {NoCurrencyRaised}

        _parameters = _toValidConstructorParameters(_parameters);
        _deployMockToken(_parameters.totalSupply);
        _deployMockCurrency(_parameters.totalSupply);

        _deployStrategy(_parameters);

        vm.assume(_blockNumber >= _parameters.migratorParams.migrationBlock);
        vm.roll(_blockNumber);

        mockAuctionCheckpoint(lbp);
        mockCurrencyRaised(lbp, 0);

        $parameters = _parameters;
        $revertData = abi.encodeWithSelector(ILBPStrategyBase.NoCurrencyRaised.selector);
    }

    modifier whenBalanceIsLessThanCurrencyAmount() {
        _;
    }

    function test_WhenBalanceIsLessThanCurrencyAmount(
        FuzzConstructorParameters memory _parameters,
        uint64 _blockNumber,
        uint128 _currencyAmount,
        uint128 _currencyBalance,
        bool _useNativeCurrency
    ) public whenBalanceIsLessThanCurrencyAmount handleMigrate {
        // it reverts with {InsufficientCurrency}

        vm.assume(_currencyBalance < type(uint128).max);

        _parameters = _toValidConstructorParameters(_parameters, _useNativeCurrency);

        _deployMockToken(_parameters.totalSupply);
        _deployMockCurrency(_currencyAmount);

        _deployStrategy(_parameters);

        vm.assume(_blockNumber >= _parameters.migratorParams.migrationBlock);
        vm.roll(_blockNumber);

        if (_useNativeCurrency) {
            vm.deal(address(lbp), _currencyBalance);
        } else {
            deal(address(_parameters.migratorParams.currency), address(lbp), _currencyBalance);
        }

        _currencyAmount = uint128(_bound(_currencyAmount, _currencyBalance + 1, type(uint128).max));
        mockAuctionCheckpoint(lbp);
        mockCurrencyRaised(lbp, _currencyAmount);

        $parameters = _parameters;
        $revertData =
            abi.encodeWithSelector(ILBPStrategyBase.InsufficientCurrency.selector, _currencyAmount, _currencyBalance);
    }
}
