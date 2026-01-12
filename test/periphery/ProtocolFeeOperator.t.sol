// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";
import {ProtocolFeeOperator} from "../../src/periphery/ProtocolFeeOperator.sol";
import {ILBPStrategyBase} from "../../src/interfaces/ILBPStrategyBase.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

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

contract ProtocolFeeOperatorTest is Test {
    ProtocolFeeOperator public implementation;

    address public protocolFeeRecipient = makeAddr("protocolFeeRecipient");
    address public owner = makeAddr("owner");
    ILBPStrategyBase public lbp;

    ERC20Mock public token;
    ERC20Mock public currency;

    function setUp() public {
        implementation = new ProtocolFeeOperator(protocolFeeRecipient);
        token = new ERC20Mock();
        currency = new ERC20Mock();
        lbp = ILBPStrategyBase(address(new MockLBP(address(token), address(currency))));
    }

    function test_implementation_isNotInitializable() public {
        assertEq(implementation.owner(), address(0));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(owner);
    }

    function test_initialize_succeeds(address _owner) public {
        ProtocolFeeOperator protocolFeeOperator = ProtocolFeeOperator(payable(Clones.clone(address(implementation))));
        assertEq(protocolFeeOperator.owner(), address(0));

        vm.expectEmit(true, true, true, true);
        emit ProtocolFeeOperator.OwnershipTransferred(address(0), _owner);
        protocolFeeOperator.initialize(_owner);
        assertEq(protocolFeeOperator.owner(), _owner);
    }

    function test_initializer_preventsDoubleInitialization(address _owner) public {
        ProtocolFeeOperator protocolFeeOperator = ProtocolFeeOperator(payable(Clones.clone(address(implementation))));
        protocolFeeOperator.initialize(_owner);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        protocolFeeOperator.initialize(_owner);
    }

    function test_transferOwnership_succeeds(address _newOwner) public {
        ProtocolFeeOperator protocolFeeOperator = ProtocolFeeOperator(payable(Clones.clone(address(implementation))));
        protocolFeeOperator.initialize(owner);

        vm.prank(owner);
        protocolFeeOperator.transferOwnership(_newOwner);
        assertEq(protocolFeeOperator.owner(), _newOwner);
    }

    function test_sweepToken_succeeds(address _recipient, uint256 _amount) public {
        ProtocolFeeOperator protocolFeeOperator = ProtocolFeeOperator(payable(Clones.clone(address(implementation))));
        protocolFeeOperator.initialize(owner);

        vm.assume(_amount > 0 && _amount <= type(uint256).max / protocolFeeOperator.PROTOCOL_FEE_BPS());
        vm.assume(_recipient != address(0));

        token.mint(address(lbp), _amount);

        vm.prank(owner);
        protocolFeeOperator.sweepToken(lbp, _recipient);
        assertEq(token.balanceOf(_recipient), _amount);
    }

    function test_sweepCurrency_succeeds(address _recipient, uint256 _amount) public {
        ProtocolFeeOperator protocolFeeOperator = ProtocolFeeOperator(payable(Clones.clone(address(implementation))));
        protocolFeeOperator.initialize(owner);

        vm.assume(_amount > 0 && _amount <= type(uint256).max / protocolFeeOperator.PROTOCOL_FEE_BPS());
        vm.assume(_recipient != address(0) && _recipient != protocolFeeRecipient);

        currency.mint(address(lbp), _amount);

        uint256 protocolFee = _amount * protocolFeeOperator.PROTOCOL_FEE_BPS() / protocolFeeOperator.BPS();
        uint256 remaining = _amount - protocolFee;

        vm.prank(owner);
        protocolFeeOperator.sweepCurrency(lbp, _recipient);
        assertEq(currency.balanceOf(protocolFeeRecipient), protocolFee);
        assertEq(currency.balanceOf(_recipient), remaining);
    }
}
