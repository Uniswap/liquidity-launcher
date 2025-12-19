// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {PositionFeesForwarder} from "../../src/periphery/PositionFeesForwarder.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TimelockedPositionRecipient} from "../../src/periphery/TimelockedPositionRecipient.sol";
import {TimelockedPositionRecipientTest} from "./TimelockedPositionRecipient.t.sol";
import {ITimelockedPositionRecipient} from "../../src/interfaces/ITimelockedPositionRecipient.sol";

// Minimal interfaces for testing
interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

contract PositionFeesForwarderTest is TimelockedPositionRecipientTest {
    using CurrencyLibrary for Currency;

    PositionFeesForwarder internal positionRecipient;

    // Fork testing vars
    // Position created here: https://etherscan.io/tx/0x03dafd828c6b47362b1f53d7a692f8f52b8bc44b513f8c9caa9195e1061113a4
    // And the fork block is a few blocks after, allowing the position to have non zero fees
    uint256 constant FORK_BLOCK = 23936030;
    uint256 constant FORK_TOKEN_ID = 107192;

    MockERC20 token;
    MockERC20 currency;

    address feeRecipient;

    function setUp() public virtual override {
        // Setups up fork and operator/searcher
        super.setUp();
        vm.createSelectFork(vm.envString("QUICKNODE_RPC_URL"), FORK_BLOCK);
        token = new MockERC20("Test Token", "TEST", 1_000e18, address(this));
        currency = new MockERC20("Test Currency", "TESTC", 1_000e18, address(this));

        feeRecipient = makeAddr("feeRecipient");
        vm.label(feeRecipient, "feeRecipient");
    }

    // Return a basic BuybackAndBurnPositionRecipient for compatibility with TimelockedPositionRecipientTest
    function _getPositionRecipient(uint64 _timelockBlockNumber)
        internal
        virtual
        override
        returns (ITimelockedPositionRecipient)
    {
        return new PositionFeesForwarder(
            IPositionManager(POSITION_MANAGER), operator, _timelockBlockNumber, feeRecipient
        );
    }

    function test_CanBeConstructed(uint256 _timelockBlockNumber, address _feeRecipient) public {
        positionRecipient = new PositionFeesForwarder(
            IPositionManager(POSITION_MANAGER), operator, _timelockBlockNumber, _feeRecipient
        );

        assertEq(positionRecipient.timelockBlockNumber(), _timelockBlockNumber);
        assertEq(positionRecipient.operator(), operator);
        assertEq(address(positionRecipient.positionManager()), POSITION_MANAGER);
        assertEq(positionRecipient.feeRecipient(), _feeRecipient);
    }

    function test_collectFees_revertsIfPositionIsNotOwner() public {
        positionRecipient = new PositionFeesForwarder(IPositionManager(POSITION_MANAGER), operator, 0, feeRecipient);
        vm.expectRevert(TimelockedPositionRecipient.NotPositionOwner.selector);
        positionRecipient.collectFees(FORK_TOKEN_ID);
    }

    /// forge-config: default.isolate = true
    /// forge-config: ci.isolate = true
    function test_collectFees_transfersBothFeesToCaller() public {
        positionRecipient = new PositionFeesForwarder(IPositionManager(POSITION_MANAGER), operator, 0, feeRecipient);
        _yoinkPosition(FORK_TOKEN_ID, address(positionRecipient));

        uint256 feeRecipientUSDCBalanceBefore = Currency.wrap(USDC).balanceOf(feeRecipient);
        uint256 feeRecipientNATIVEBalanceBefore = Currency.wrap(NATIVE).balanceOf(feeRecipient);

        vm.prank(searcher);
        vm.expectEmit(true, true, true, true);
        emit PositionFeesForwarder.FeesForwarded(feeRecipient);
        positionRecipient.collectFees(FORK_TOKEN_ID);
        vm.snapshotGasLastCall("collectFees"); // This gas snap isn't super accurate bc its forked but good enough for now
        assertGt(
            Currency.wrap(USDC).balanceOf(feeRecipient),
            feeRecipientUSDCBalanceBefore,
            "Fee recipient USDC balance did not increase"
        );
        assertGt(
            Currency.wrap(NATIVE).balanceOf(feeRecipient),
            feeRecipientNATIVEBalanceBefore,
            "Fee recipient currency balance did not increase"
        );
        assertEq(
            Currency.wrap(USDC).balanceOf(address(positionRecipient)), 0, "Position recipient USDC balance is not 0"
        );
        assertEq(
            Currency.wrap(NATIVE).balanceOf(address(positionRecipient)),
            0,
            "Position recipient currency balance is not 0"
        );
    }
}
