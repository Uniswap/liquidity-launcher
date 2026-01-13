// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";
import {ProtocolFeeOperator} from "../../src/periphery/ProtocolFeeOperator.sol";
import {ILBPStrategyBase} from "../../src/interfaces/ILBPStrategyBase.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

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

contract ProtocolFeeOperatorTest is Test {
    ProtocolFeeOperator public implementation;
    MockProtocolFeeController public protocolFeeController;

    address public protocolFeeRecipient = makeAddr("protocolFeeRecipient");
    ILBPStrategyBase public lbp;

    ERC20Mock public token;
    ERC20Mock public currency;

    uint24 public constant BPS = 10_000;

    function setUp() public {
        protocolFeeController = new MockProtocolFeeController();
        implementation = new ProtocolFeeOperator(protocolFeeRecipient, address(protocolFeeController));
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

    function test_sweepToken_succeeds(address _recipient, uint256 _amount) public {
        ProtocolFeeOperator protocolFeeOperator = ProtocolFeeOperator(payable(Clones.clone(address(implementation))));
        protocolFeeOperator.initialize(address(lbp), _recipient);

        vm.assume(_amount > 0);
        vm.assume(_recipient != address(0));

        token.mint(address(lbp), _amount);

        protocolFeeOperator.sweepToken();
        assertEq(token.balanceOf(_recipient), _amount);
    }

    function test_sweepCurrency_protocolFeeController_returnsZero_zeroFee(address _recipient, uint256 _amount) public {
        ProtocolFeeOperator protocolFeeOperator = ProtocolFeeOperator(payable(Clones.clone(address(implementation))));
        protocolFeeOperator.initialize(address(lbp), _recipient);

        vm.assume(_amount > 0 && _amount <= type(uint128).max);
        vm.assume(_recipient != address(0) && _recipient != protocolFeeRecipient && _recipient != address(lbp));

        currency.mint(address(lbp), _amount);

        protocolFeeOperator.sweepCurrency();
        assertEq(currency.balanceOf(_recipient), _amount);
        assertEq(protocolFeeOperator.index(), 0);
    }

    function test_sweepCurrency_protocolFeeController_returnsLessThanMax(
        address _recipient,
        uint256 _amount,
        uint24 _protocolFeeBps,
        uint256 _releaseBlock
    ) public {
        _protocolFeeBps = uint24(bound(_protocolFeeBps, 1, implementation.MAX_PROTOCOL_FEE_BPS()));
        protocolFeeController.setProtocolFeeBps(_protocolFeeBps);
        ProtocolFeeOperator protocolFeeOperator = ProtocolFeeOperator(payable(Clones.clone(address(implementation))));
        protocolFeeOperator.initialize(address(lbp), _recipient);

        vm.assume(_amount > 0 && _amount <= type(uint128).max);
        vm.assume(_recipient != address(0) && _recipient != protocolFeeRecipient && _recipient != address(lbp));

        currency.mint(address(lbp), _amount);

        uint256 protocolFeeIndex = _amount * _protocolFeeBps;
        uint256 remaining = _amount * (BPS - _protocolFeeBps) / BPS;

        protocolFeeOperator.sweepCurrency();
        assertEq(currency.balanceOf(_recipient), remaining, "balance");
        assertEq(protocolFeeOperator.index(), protocolFeeIndex, "index");

        _releaseBlock = bound(_releaseBlock, block.number + 1, block.number + BPS);
        uint256 elapsed = _releaseBlock - block.number;
        uint256 indexDelta =
            FixedPointMathLib.fullMulDiv(protocolFeeIndex, elapsed * protocolFeeOperator.BPS_RELEASED_PER_BLOCK(), BPS);
        if (indexDelta > protocolFeeIndex) indexDelta = protocolFeeIndex;
        uint256 toRelease = indexDelta / BPS;
        if (toRelease > 0) {
            vm.expectEmit(true, true, true, true);
            emit ProtocolFeeOperator.ProtocolFeeReleased(lbp.currency(), toRelease);
        }

        vm.roll(_releaseBlock);
        protocolFeeOperator.release();
        assertEq(currency.balanceOf(protocolFeeRecipient), toRelease, "balance");
        assertEq(protocolFeeOperator.index(), protocolFeeIndex - indexDelta, "index");
    }

    function test_sweepCurrency_protocolFeeController_returnsMaxWhenOverMax(
        address _recipient,
        uint256 _amount,
        uint24 _protocolFeeBps,
        uint256 _releaseBlock
    ) public {
        _protocolFeeBps = uint24(bound(_protocolFeeBps, implementation.MAX_PROTOCOL_FEE_BPS() + 1, type(uint24).max));
        protocolFeeController.setProtocolFeeBps(_protocolFeeBps);
        ProtocolFeeOperator protocolFeeOperator = ProtocolFeeOperator(payable(Clones.clone(address(implementation))));
        protocolFeeOperator.initialize(address(lbp), _recipient);

        vm.assume(_amount > 0 && _amount <= type(uint128).max);
        vm.assume(_recipient != address(0) && _recipient != protocolFeeRecipient && _recipient != address(lbp));

        currency.mint(address(lbp), _amount);

        uint256 protocolFeeIndex = _amount * protocolFeeOperator.MAX_PROTOCOL_FEE_BPS();

        protocolFeeOperator.sweepCurrency();
        assertEq(
            currency.balanceOf(_recipient),
            _amount * (BPS - protocolFeeOperator.MAX_PROTOCOL_FEE_BPS()) / BPS,
            "balance"
        );
        assertEq(protocolFeeOperator.index(), protocolFeeIndex, "index");

        _releaseBlock = bound(_releaseBlock, block.number + 1, block.number + BPS);
        uint256 elapsed = _releaseBlock - block.number;
        uint256 indexDelta =
            FixedPointMathLib.fullMulDiv(protocolFeeIndex, elapsed * protocolFeeOperator.BPS_RELEASED_PER_BLOCK(), BPS);
        if (indexDelta > protocolFeeIndex) indexDelta = protocolFeeIndex;
        uint256 toRelease = indexDelta / BPS;
        if (toRelease > 0) {
            vm.expectEmit(true, true, true, true);
            emit ProtocolFeeOperator.ProtocolFeeReleased(lbp.currency(), toRelease);
        }
        vm.roll(_releaseBlock);
        protocolFeeOperator.release();
        assertEq(currency.balanceOf(protocolFeeRecipient), toRelease, "balance");
        assertEq(protocolFeeOperator.index(), protocolFeeIndex - indexDelta, "index");
    }

    function test_release_multipleReleases(
        address _recipient,
        uint256 _amount,
        uint24 _protocolFeeBps,
        uint256 _nextSweepCurrencyBlock
    ) public {
        _protocolFeeBps = uint24(bound(_protocolFeeBps, 1, implementation.MAX_PROTOCOL_FEE_BPS()));
        protocolFeeController.setProtocolFeeBps(_protocolFeeBps);
        ProtocolFeeOperator protocolFeeOperator = ProtocolFeeOperator(payable(Clones.clone(address(implementation))));
        protocolFeeOperator.initialize(address(lbp), _recipient);

        vm.assume(_amount > 0 && _amount <= type(uint128).max);
        vm.assume(_recipient != address(0) && _recipient != protocolFeeRecipient && _recipient != address(lbp));

        currency.mint(address(lbp), _amount);
        uint256 protocolFeeIndex = _amount * _protocolFeeBps;
        protocolFeeOperator.sweepCurrency();
        assertEq(protocolFeeOperator.index(), protocolFeeIndex, "index");

        // roll somewhere between the start of the first drip and its end
        _nextSweepCurrencyBlock = bound(
            _nextSweepCurrencyBlock, block.number + 1, block.number + BPS / protocolFeeOperator.BPS_RELEASED_PER_BLOCK()
        );

        uint256 elapsed = _nextSweepCurrencyBlock - block.number;
        uint256 indexDelta =
            FixedPointMathLib.fullMulDiv(protocolFeeIndex, elapsed * protocolFeeOperator.BPS_RELEASED_PER_BLOCK(), BPS);
        if (indexDelta > protocolFeeIndex) indexDelta = protocolFeeIndex;
        uint256 toRelease = indexDelta / BPS;
        if (toRelease > 0) {
            vm.expectEmit(true, true, true, true);
            emit ProtocolFeeOperator.ProtocolFeeReleased(lbp.currency(), toRelease);
        }
        vm.roll(_nextSweepCurrencyBlock);
        protocolFeeOperator.release();

        uint256 remainingIndex = protocolFeeOperator.index();
        currency.mint(address(lbp), _amount);
        protocolFeeOperator.sweepCurrency();
        assertEq(protocolFeeOperator.index(), remainingIndex + protocolFeeIndex, "index");

        // Roll past the end of the second drip
        vm.roll(block.number + BPS);

        toRelease = (remainingIndex + protocolFeeIndex) / BPS;
        if (toRelease > 0) {
            vm.expectEmit(true, true, true, true);
            emit ProtocolFeeOperator.ProtocolFeeReleased(lbp.currency(), toRelease);
        }
        protocolFeeOperator.release();
        assertEq(protocolFeeOperator.index(), 0);
    }
}
