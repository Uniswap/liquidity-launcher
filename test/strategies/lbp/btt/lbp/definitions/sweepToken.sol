// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BttBase} from "../BttBase.sol";
import {ILBPStrategyBase} from "src/interfaces/ILBPStrategyBase.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {FuzzConstructorParameters} from "../BttBase.sol";

abstract contract SweepTokenTest is BttBase {
    function test_WhenBlockNumberLTSweepBlock(FuzzConstructorParameters memory _parameters, uint64 _blockNumber)
        public
    {
        // it reverts with {SweepNotAllowed}

        _parameters = _toValidConstructorParameters(_parameters);
        _deployMockToken(_parameters.totalSupply);

        _deployStrategy(_parameters);

        vm.assume(_blockNumber < _parameters.migratorParams.sweepBlock);
        vm.roll(_blockNumber);

        vm.expectRevert(
            abi.encodeWithSelector(
                ILBPStrategyBase.SweepNotAllowed.selector, _parameters.migratorParams.sweepBlock, _blockNumber
            )
        );
        lbp.sweepToken();
    }

    modifier whenBlockNumberIsGTESweepBlock() {
        _;
    }

    function test_WhenMsgSenderIsNotOperator(
        FuzzConstructorParameters memory _parameters,
        uint64 _blockNumber,
        address _caller
    ) public whenBlockNumberIsGTESweepBlock {
        // it reverts with {NotOperator}

        _parameters = _toValidConstructorParameters(_parameters);
        _deployMockToken(_parameters.totalSupply);

        vm.assume(_caller != _parameters.migratorParams.operator);

        _deployStrategy(_parameters);

        vm.assume(_blockNumber >= _parameters.migratorParams.sweepBlock);
        vm.roll(_blockNumber);

        vm.prank(_caller);
        vm.expectRevert(
            abi.encodeWithSelector(ILBPStrategyBase.NotOperator.selector, _caller, _parameters.migratorParams.operator)
        );
        lbp.sweepToken();
    }

    modifier whenMsgSenderIsOperator() {
        _;
    }

    function test_WhenTokenBalanceIsZero(FuzzConstructorParameters memory _parameters, uint64 _blockNumber)
        public
        whenMsgSenderIsOperator
    {
        // it does not sweep the tokens

        _parameters = _toValidConstructorParameters(_parameters);
        _deployMockToken(_parameters.totalSupply);

        _deployStrategy(_parameters);

        vm.assume(_blockNumber >= _parameters.migratorParams.sweepBlock);
        vm.roll(_blockNumber);

        uint256 operatorTokenBalanceBefore =
            Currency.wrap(address(token)).balanceOf(_parameters.migratorParams.operator);
        vm.prank(_parameters.migratorParams.operator);
        lbp.sweepToken();
        uint256 operatorTokenBalanceAfter = Currency.wrap(address(token)).balanceOf(_parameters.migratorParams.operator);
        assertEq(operatorTokenBalanceAfter, operatorTokenBalanceBefore, "Operator token balance should not change");
    }

    modifier whenTokenBalanceIsGreaterThanZero() {
        _;
    }

    function test_WhenTokenBalanceIsGreaterThanZero(FuzzConstructorParameters memory _parameters, uint64 _blockNumber)
        public
        whenTokenBalanceIsGreaterThanZero
    {
        // it sweeps the tokens
        // it emits {TokensSwept}

        _parameters = _toValidConstructorParameters(_parameters);
        _deployMockToken(_parameters.totalSupply);

        _deployStrategy(_parameters);

        vm.assume(_blockNumber >= _parameters.migratorParams.sweepBlock);
        vm.roll(_blockNumber);

        vm.prank(address(liquidityLauncher));
        token.transfer(address(lbp), _parameters.totalSupply);

        vm.prank(_parameters.migratorParams.operator);
        vm.expectEmit(true, true, true, true);
        emit ILBPStrategyBase.TokensSwept(_parameters.migratorParams.operator, _parameters.totalSupply);
        lbp.sweepToken();
    }
}
