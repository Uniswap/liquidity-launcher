// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {PositionFeesForwarder} from "../../src/periphery/PositionFeesForwarder.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC721} from "../../src/interfaces/external/IERC721.sol";
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
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant NATIVE = 0x0000000000000000000000000000000000000000;
    uint256 constant FORK_BLOCK = 23936030;
    uint256 constant FORK_TOKEN_ID = 107192;

    MockERC20 token;
    MockERC20 currency;

    address recipient;

    function setUp() public virtual override {
        // Setups up fork and operator/searcher
        super.setUp();
        vm.createSelectFork(vm.envString("QUICKNODE_RPC_URL"), FORK_BLOCK);
        token = new MockERC20("Test Token", "TEST", 1_000e18, address(this));
        currency = new MockERC20("Test Currency", "TESTC", 1_000e18, address(this));

        recipient = makeAddr("recipient");
        vm.label(recipient, "recipient");
    }

    // Return a basic BuybackAndBurnPositionRecipient for compatibility with TimelockedPositionRecipientTest
    function _getPositionRecipient(uint64 _timelockBlockNumber)
        internal
        virtual
        override
        returns (ITimelockedPositionRecipient)
    {
        return new PositionFeesForwarder(IPositionManager(POSITION_MANAGER), operator, _timelockBlockNumber, recipient);
    }

    // Transfer a v4 position from one owner to another
    function _yoinkPosition(uint256 _tokenId, address _newOwner) internal {
        address originalOwner = IERC721(POSITION_MANAGER).ownerOf(_tokenId);
        vm.prank(originalOwner);
        IERC721(POSITION_MANAGER).transferFrom(originalOwner, _newOwner, _tokenId);
        assertEq(IERC721(POSITION_MANAGER).ownerOf(_tokenId), _newOwner);
    }

    // Deal USDC from the pool manager to an address
    // vm.deal() doesn't work well for USDC
    function _dealUSDCFromPoolManager(address _to, uint256 _amount) internal {
        vm.prank(POOL_MANAGER);
        bool success = IERC20(USDC).transfer(_to, _amount);
        assertTrue(success);
    }

    function test_CanBeConstructed(uint256 _timelockBlockNumber, address _recipient) public {
        positionRecipient =
            new PositionFeesForwarder(IPositionManager(POSITION_MANAGER), operator, _timelockBlockNumber, _recipient);

        assertEq(positionRecipient.TIMELOCK_BLOCK_NUMBER(), _timelockBlockNumber);
        assertEq(positionRecipient.OPERATOR(), operator);
        assertEq(address(positionRecipient.POSITION_MANAGER()), POSITION_MANAGER);
        assertEq(positionRecipient.RECIPIENT(), _recipient);
    }

    function test_collectFees_revertsIfPositionIsNotOwner() public {
        positionRecipient = new PositionFeesForwarder(IPositionManager(POSITION_MANAGER), operator, 0, recipient);
        vm.expectRevert(PositionFeesForwarder.NotPositionOwner.selector);
        positionRecipient.collectFees(FORK_TOKEN_ID, USDC, NATIVE);
    }

    function test_collectFees_revertsIfTokenOrCurrencyAreWrong(address _token, address _currency) public {
        vm.assume((_token != USDC && _token != NATIVE) || (_currency != USDC && _currency != NATIVE));
        positionRecipient = new PositionFeesForwarder(IPositionManager(POSITION_MANAGER), operator, 0, recipient);
        _yoinkPosition(FORK_TOKEN_ID, address(positionRecipient));

        vm.expectRevert(bytes4(keccak256("CurrencyNotSettled()")));
        positionRecipient.collectFees(FORK_TOKEN_ID, _token, _currency);
    }

    function test_collectFees_transfersBothFeesToCaller() public {
        positionRecipient = new PositionFeesForwarder(IPositionManager(POSITION_MANAGER), operator, 0, recipient);
        _yoinkPosition(FORK_TOKEN_ID, address(positionRecipient));

        uint256 recipientUSDCBalanceBefore = Currency.wrap(USDC).balanceOf(recipient);
        uint256 recipientNATIVEBalanceBefore = Currency.wrap(NATIVE).balanceOf(recipient);

        vm.prank(searcher);
        vm.expectEmit(true, true, true, true);
        // Hardcoded fees owed from the forked position
        emit PositionFeesForwarder.FeesForwarded(recipient, 12508370, 709706242928);
        positionRecipient.collectFees(FORK_TOKEN_ID, USDC, NATIVE);
        assertGt(
            Currency.wrap(USDC).balanceOf(recipient),
            recipientUSDCBalanceBefore,
            "Recipient USDC balance did not increase"
        );
        assertGt(
            Currency.wrap(NATIVE).balanceOf(recipient),
            recipientNATIVEBalanceBefore,
            "Recipient NATIVE balance did not increase"
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
