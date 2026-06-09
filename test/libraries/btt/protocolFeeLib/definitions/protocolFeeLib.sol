// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ProtocolFeeLib} from "src/libraries/ProtocolFeeLib.sol";
import {IProtocolFeeController} from "src/interfaces/IProtocolFeeController.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

contract ProtocolFeeLibHarness {
    function getProtocolFeeAmount(IProtocolFeeController controller, address currency, uint256 amount)
        external
        view
        returns (uint256)
    {
        return ProtocolFeeLib.getProtocolFeeAmount(controller, currency, amount);
    }

    function transferProtocolFee(IProtocolFeeController controller, address currency, uint256 protocolFeeAmount)
        external
    {
        ProtocolFeeLib.transferProtocolFee(controller, currency, protocolFeeAmount);
    }

    receive() external payable {}
}

contract MockProtocolFeeController is IProtocolFeeController {
    address public protocolFeeRecipient;

    address public expectedCurrency;
    uint256 public expectedAmount;
    uint256 public protocolFeeAmount;

    function setExpectedFee(address currency, uint256 amount, uint256 feeAmount) external {
        expectedCurrency = currency;
        expectedAmount = amount;
        protocolFeeAmount = feeAmount;
    }

    function setProtocolFeeRecipient(address recipient) external {
        protocolFeeRecipient = recipient;
    }

    function setGlobalProtocolFeePips(uint24) external {}

    function setProtocolFeeBracketsForCurrency(address, ProtocolFeeBracket[] calldata) external {}

    function getProtocolFeeBracketsForCurrency(address) external pure returns (ProtocolFeeBracket[] memory fees) {
        return fees;
    }

    function getProtocolFeeAmount(address currency, uint256 amount) external view returns (uint256) {
        require(currency == expectedCurrency, "unexpected currency");
        require(amount == expectedAmount, "unexpected amount");
        return protocolFeeAmount;
    }
}

contract RevertingProtocolFeeController is IProtocolFeeController {
    function protocolFeeRecipient() external pure returns (address) {
        return address(0);
    }

    function setProtocolFeeRecipient(address) external {}

    function setGlobalProtocolFeePips(uint24) external {}

    function setProtocolFeeBracketsForCurrency(address, ProtocolFeeBracket[] calldata) external {}

    function getProtocolFeeBracketsForCurrency(address) external pure returns (ProtocolFeeBracket[] memory fees) {
        return fees;
    }

    function getProtocolFeeAmount(address, uint256) external pure returns (uint256) {
        revert("controller reverted");
    }
}

/// @title ProtocolFeeLibTest
/// @notice BTT tests for ProtocolFeeLib
///
/// getProtocolFeeAmount
/// ├── when protocol fee controller is unset
/// │   └── it returns zero
/// └── when protocol fee controller is set
///     ├── when the controller call reverts
///     │   └── it returns zero
///     └── when the controller call succeeds
///         └── it returns the controller fee amount
///
/// transferProtocolFee
/// ├── when currency is native
/// │   ├── it transfers native currency to the protocol fee recipient
/// │   └── it emits ProtocolFeeTransferred
/// └── when currency is ERC20
///     ├── it transfers tokens to the protocol fee recipient
///     └── it emits ProtocolFeeTransferred
contract ProtocolFeeLibTest is Test {
    event ProtocolFeeTransferred(address indexed currency, uint256 protocolFeeAmount);

    ProtocolFeeLibHarness public harness;
    MockProtocolFeeController public controller;

    address public recipient = makeAddr("recipient");

    function setUp() public {
        harness = new ProtocolFeeLibHarness();
        controller = new MockProtocolFeeController();
        controller.setProtocolFeeRecipient(recipient);
    }

    function test_GetProtocolFeeAmount_WhenProtocolFeeControllerIsUnset_ReturnsZero(address _currency, uint256 _amount)
        public
        view
    {
        // it returns zero
        uint256 feeAmount = harness.getProtocolFeeAmount(IProtocolFeeController(address(0)), _currency, _amount);

        assertEq(feeAmount, 0);
    }

    function test_GetProtocolFeeAmount_WhenTheControllerCallReverts_ReturnsZero(address _currency, uint256 _amount)
        public
    {
        // it returns zero
        RevertingProtocolFeeController revertingController = new RevertingProtocolFeeController();

        uint256 feeAmount = harness.getProtocolFeeAmount(revertingController, _currency, _amount);

        assertEq(feeAmount, 0);
    }

    function test_GetProtocolFeeAmount_WhenTheControllerCallSucceeds_ReturnsControllerFeeAmount(
        address _currency,
        uint256 _amount,
        uint256 _feeAmount
    ) public {
        // it returns the controller fee amount
        controller.setExpectedFee(_currency, _amount, _feeAmount);

        uint256 feeAmount = harness.getProtocolFeeAmount(controller, _currency, _amount);

        assertEq(feeAmount, _feeAmount);
    }

    function test_TransferProtocolFee_WhenCurrencyIsNative_TransfersNativeCurrencyToProtocolFeeRecipient(uint256 _protocolFeeAmount)
        public
    {
        // it transfers native currency to the protocol fee recipient
        _protocolFeeAmount = bound(_protocolFeeAmount, 0, type(uint128).max);
        address currency = address(0);
        vm.deal(address(harness), _protocolFeeAmount);

        uint256 recipientBalanceBefore = recipient.balance;

        vm.expectEmit(true, true, true, true, address(harness));
        emit ProtocolFeeTransferred(currency, _protocolFeeAmount);
        harness.transferProtocolFee(controller, currency, _protocolFeeAmount);

        assertEq(recipient.balance - recipientBalanceBefore, _protocolFeeAmount);
        assertEq(address(harness).balance, 0);
    }

    function test_TransferProtocolFee_WhenCurrencyIsERC20_TransfersTokensToProtocolFeeRecipient(uint256 _protocolFeeAmount)
        public
    {
        // it transfers tokens to the protocol fee recipient
        _protocolFeeAmount = bound(_protocolFeeAmount, 0, type(uint128).max);

        MockERC20 token = new MockERC20("Test Token", "TT", _protocolFeeAmount, address(harness));
        address currency = address(token);

        uint256 recipientBalanceBefore = token.balanceOf(recipient);

        vm.expectEmit(true, true, true, true, address(harness));
        emit ProtocolFeeTransferred(currency, _protocolFeeAmount);
        harness.transferProtocolFee(controller, currency, _protocolFeeAmount);

        assertEq(token.balanceOf(recipient) - recipientBalanceBefore, _protocolFeeAmount);
        assertEq(token.balanceOf(address(harness)), 0);
    }
}
