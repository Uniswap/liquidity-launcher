// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";
import {ProtocolFeeOperator} from "../../src/periphery/ProtocolFeeOperator.sol";
import {ILBPStrategyBase} from "../../src/interfaces/ILBPStrategyBase.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {FeeTapper} from "../../src/periphery/FeeTapper.sol";

/// @title MockLBP for testing the ProtocolFeeOperator
/// @notice Sweeps its token and currency balance to the caller
contract MockLBP {
    using CurrencyLibrary for Currency;
    Currency public immutable token;
    Currency public immutable currency;

    constructor(address _token, address _currency) {
        token = Currency.wrap(_token);
        currency = Currency.wrap(_currency);
    }

    function sweepToken() external {
        token.transfer(msg.sender, token.balanceOfSelf());
    }

    function sweepCurrency() external {
        currency.transfer(msg.sender, currency.balanceOfSelf());
    }
}

contract MockProtocolFeeController {
    uint24 public protocolFeeBps;

    function setProtocolFeeBps(uint24 _protocolFeeBps) external {
        protocolFeeBps = _protocolFeeBps;
    }

    function getProtocolFeeBps(address, uint256) external view returns (uint24) {
        return protocolFeeBps;
    }
}

contract MockProtocolFeeControllerReverting {
    function getProtocolFeeBps(address, uint256) external view returns (uint24) {
        revert("reverting");
    }
}

contract MockProtocolFeeControllerOverflowing {
    function getProtocolFeeBps(address, uint256) external view returns (uint256) {
        return type(uint256).max;
    }
}

contract ProtocolFeeOperatorTest is Test {
    ProtocolFeeOperator public implementation;
    MockProtocolFeeController public protocolFeeController;
    FeeTapper public feeTapper;
    ILBPStrategyBase public lbp;
    ERC20Mock public token;
    ERC20Mock public currency;

    uint24 public constant BPS = 10_000;

    function setUp() public {
        protocolFeeController = new MockProtocolFeeController();
        feeTapper = new FeeTapper(makeAddr("tokenJar"), address(this));
        implementation = new ProtocolFeeOperator(address(feeTapper), address(protocolFeeController));
        token = new ERC20Mock();
        currency = new ERC20Mock();
        lbp = ILBPStrategyBase(address(new MockLBP(address(token), address(currency))));
    }

    function test_implementation_isNotInitializable() public {
        assertEq(implementation.recipient(), address(0));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(address(lbp), address(0));
    }

    function test_initialize_succeeds(address _lbp, address _recipient) public {
        vm.assume(_lbp != address(0));

        ProtocolFeeOperator protocolFeeOperator = ProtocolFeeOperator(payable(Clones.clone(address(implementation))));
        assertEq(protocolFeeOperator.recipient(), address(0));

        vm.expectEmit(true, true, true, true);
        emit ProtocolFeeOperator.RecipientSet(_recipient);
        protocolFeeOperator.initialize(_lbp, _recipient);
        assertEq(address(protocolFeeOperator.lbp()), _lbp);
        assertEq(protocolFeeOperator.recipient(), _recipient);
    }

    function test_initializer_preventsDoubleInitialization(address _lbp, address _recipient) public {
        vm.assume(_lbp != address(0));

        ProtocolFeeOperator protocolFeeOperator = ProtocolFeeOperator(payable(Clones.clone(address(implementation))));
        protocolFeeOperator.initialize(_lbp, _recipient);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        protocolFeeOperator.initialize(_lbp, _recipient);
    }

    function test_sweepToken_succeeds(address _recipient, uint128 _amount) public {
        ProtocolFeeOperator protocolFeeOperator = ProtocolFeeOperator(payable(Clones.clone(address(implementation))));
        protocolFeeOperator.initialize(address(lbp), _recipient);

        vm.assume(_amount > 0);
        vm.assume(_recipient != address(0));

        token.mint(address(lbp), _amount);

        protocolFeeOperator.sweepToken();
        assertEq(token.balanceOf(_recipient), _amount);
    }

    function test_sweepCurrency_protocolFeeController_returnsZero_zeroFee(address _recipient, uint128 _amount) public {
        ProtocolFeeOperator protocolFeeOperator = ProtocolFeeOperator(payable(Clones.clone(address(implementation))));
        protocolFeeOperator.initialize(address(lbp), _recipient);

        vm.assume(_amount > 0 && _amount <= type(uint128).max);
        vm.assume(_recipient != address(0) && _recipient != address(feeTapper) && _recipient != address(lbp));

        currency.mint(address(lbp), _amount);

        protocolFeeOperator.sweepCurrency();
        assertEq(currency.balanceOf(_recipient), _amount);
        assertEq(currency.balanceOf(address(protocolFeeOperator.feeTapper())), 0);
    }

    function test_sweepCurrency_protocolFeeController_reverts_zeroFee(address _recipient, uint128 _amount) public {
        vm.etch(address(protocolFeeController), address(new MockProtocolFeeControllerReverting()).code);
        ProtocolFeeOperator protocolFeeOperator = ProtocolFeeOperator(payable(Clones.clone(address(implementation))));
        protocolFeeOperator.initialize(address(lbp), _recipient);

        vm.assume(_amount > 0 && _amount <= type(uint128).max);
        vm.assume(_recipient != address(0) && _recipient != address(feeTapper) && _recipient != address(lbp));

        currency.mint(address(lbp), _amount);

        protocolFeeOperator.sweepCurrency();
        assertEq(currency.balanceOf(address(protocolFeeOperator.feeTapper())), 0);
        assertEq(currency.balanceOf(_recipient), _amount);
    }

    function test_sweepCurrency_protocolFeeController_overflows_returnsMax(address _recipient, uint128 _amount) public {
        vm.etch(address(protocolFeeController), address(new MockProtocolFeeControllerOverflowing()).code);
        ProtocolFeeOperator protocolFeeOperator = ProtocolFeeOperator(payable(Clones.clone(address(implementation))));
        protocolFeeOperator.initialize(address(lbp), _recipient);

        vm.assume(_amount > 0 && _amount <= type(uint128).max / implementation.MAX_PROTOCOL_FEE_BPS());
        vm.assume(_recipient != address(0) && _recipient != address(feeTapper) && _recipient != address(lbp));

        currency.mint(address(lbp), _amount);
        uint128 protocolFeeAmount = _amount * implementation.MAX_PROTOCOL_FEE_BPS() / BPS;

        protocolFeeOperator.sweepCurrency();
        assertEq(currency.balanceOf(address(protocolFeeOperator.feeTapper())), protocolFeeAmount);
        assertEq(currency.balanceOf(_recipient), _amount - protocolFeeAmount);
    }

    function test_sweepCurrency_protocolFeeController_returnsLessThanMax(
        address _recipient,
        uint128 _amount,
        uint24 _protocolFeeBps
    ) public {
        _protocolFeeBps = uint24(bound(_protocolFeeBps, 1, implementation.MAX_PROTOCOL_FEE_BPS()));
        protocolFeeController.setProtocolFeeBps(_protocolFeeBps);
        ProtocolFeeOperator protocolFeeOperator = ProtocolFeeOperator(payable(Clones.clone(address(implementation))));
        protocolFeeOperator.initialize(address(lbp), _recipient);

        vm.assume(_amount > 0 && _amount <= type(uint128).max / implementation.MAX_PROTOCOL_FEE_BPS());
        vm.assume(_recipient != address(0) && _recipient != address(feeTapper) && _recipient != address(lbp));

        currency.mint(address(lbp), _amount);

        uint128 protocolFeeAmount = _amount * _protocolFeeBps / BPS;

        protocolFeeOperator.sweepCurrency();
        assertEq(currency.balanceOf(address(protocolFeeOperator.feeTapper())), protocolFeeAmount);
        assertEq(currency.balanceOf(_recipient), _amount - protocolFeeAmount);
    }

    function test_sweepCurrency_protocolFeeController_returnsMaxWhenOverMax(
        address _recipient,
        uint128 _amount,
        uint24 _protocolFeeBps
    ) public {
        _protocolFeeBps = uint24(bound(_protocolFeeBps, implementation.MAX_PROTOCOL_FEE_BPS() + 1, type(uint24).max));
        protocolFeeController.setProtocolFeeBps(_protocolFeeBps);
        ProtocolFeeOperator protocolFeeOperator = ProtocolFeeOperator(payable(Clones.clone(address(implementation))));
        protocolFeeOperator.initialize(address(lbp), _recipient);

        vm.assume(_amount > 0 && _amount <= type(uint128).max / implementation.MAX_PROTOCOL_FEE_BPS());
        vm.assume(_recipient != address(0) && _recipient != address(feeTapper) && _recipient != address(lbp));

        currency.mint(address(lbp), _amount);

        uint128 protocolFeeAmount = _amount * implementation.MAX_PROTOCOL_FEE_BPS() / BPS;

        protocolFeeOperator.sweepCurrency();
        assertEq(currency.balanceOf(address(protocolFeeOperator.feeTapper())), protocolFeeAmount);
        assertEq(currency.balanceOf(_recipient), _amount - protocolFeeAmount);
    }
}
