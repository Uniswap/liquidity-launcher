// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {BuybackAndBurnPositionRecipient} from "../../src/periphery/BuybackAndBurnPositionRecipient.sol";
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

contract BuybackAndBurnPositionRecipientTest is TimelockedPositionRecipientTest {
    using CurrencyLibrary for Currency;

    BuybackAndBurnPositionRecipient internal positionRecipient;

    // Fork testing vars
    // Position created here: https://etherscan.io/tx/0x03dafd828c6b47362b1f53d7a692f8f52b8bc44b513f8c9caa9195e1061113a4
    // And the fork block is a few blocks after, allowing the position to have non zero fees
    uint256 constant FORK_BLOCK = 23936030;
    uint256 constant FORK_TOKEN_ID = 107192;

    MockERC20 token;
    MockERC20 currency;

    function setUp() public virtual override {
        // Setups up fork and operator/searcher
        super.setUp();
        vm.createSelectFork(vm.envString("QUICKNODE_RPC_URL"), FORK_BLOCK);
        token = new MockERC20("Test Token", "TEST", 1_000e18, address(this));
        currency = new MockERC20("Test Currency", "TESTC", 1_000e18, address(this));
    }

    // Return a basic BuybackAndBurnPositionRecipient for compatibility with TimelockedPositionRecipientTest
    function _getPositionRecipient(uint64 _timelockBlockNumber)
        internal
        virtual
        override
        returns (ITimelockedPositionRecipient)
    {
        return new BuybackAndBurnPositionRecipient(
            address(token),
            address(currency),
            operator,
            IPositionManager(POSITION_MANAGER),
            _timelockBlockNumber,
            0 // 0 as min token burn amount, doesn't matter
        );
    }

    function test_CanBeConstructed(uint256 _timelockBlockNumber, uint256 _minTokenBurnAmount) public {
        positionRecipient = new BuybackAndBurnPositionRecipient(
            address(token),
            address(currency),
            operator,
            IPositionManager(POSITION_MANAGER),
            _timelockBlockNumber,
            _minTokenBurnAmount
        );

        assertEq(positionRecipient.timelockBlockNumber(), _timelockBlockNumber);
        assertEq(positionRecipient.minTokenBurnAmount(), _minTokenBurnAmount);
        assertEq(positionRecipient.token(), address(token));
        assertEq(positionRecipient.currency(), address(currency));
        assertEq(positionRecipient.operator(), operator);
        assertEq(address(positionRecipient.positionManager()), POSITION_MANAGER);
    }

    function test_RevertsIfTokenIsZeroAddress(uint256 _timelockBlockNumber, uint256 _minTokenBurnAmount) public {
        vm.expectRevert(BuybackAndBurnPositionRecipient.InvalidToken.selector);
        new BuybackAndBurnPositionRecipient(
            address(0),
            address(currency),
            operator,
            IPositionManager(POSITION_MANAGER),
            _timelockBlockNumber,
            _minTokenBurnAmount
        );
    }

    function test_RevertsIfTokenAndCurrencyAreTheSame(uint256 _timelockBlockNumber, uint256 _minTokenBurnAmount)
        public
    {
        vm.expectRevert(BuybackAndBurnPositionRecipient.TokenAndCurrencyCannotBeTheSame.selector);
        new BuybackAndBurnPositionRecipient(
            address(token),
            address(token),
            operator,
            IPositionManager(POSITION_MANAGER),
            _timelockBlockNumber,
            _minTokenBurnAmount
        );
    }

    function test_collectFees_revertsIfPositionIsNotOwner() public {
        positionRecipient =
            new BuybackAndBurnPositionRecipient(USDC, NATIVE, operator, IPositionManager(POSITION_MANAGER), 0, 0);
        vm.expectRevert(abi.encodeWithSelector(IPositionManager.NotApproved.selector, address(positionRecipient)));
        positionRecipient.collectFees(FORK_TOKEN_ID);
    }

    function test_collectFees_revertsIfMinimumBurnAmountIsNotMet(uint256 _minTokenBurnAmount) public {
        vm.assume(_minTokenBurnAmount > 0 && _minTokenBurnAmount < 1_000_000e6);

        positionRecipient = new BuybackAndBurnPositionRecipient(
            USDC, NATIVE, operator, IPositionManager(POSITION_MANAGER), 0, _minTokenBurnAmount
        );

        vm.prank(searcher);
        IERC20(USDC).approve(address(positionRecipient), type(uint256).max);
        _dealUSDCFromPoolManager(address(searcher), _minTokenBurnAmount - 1);

        _yoinkPosition(FORK_TOKEN_ID, address(positionRecipient));

        vm.expectRevert(abi.encodeWithSelector(SafeTransferLib.TransferFromFailed.selector));
        vm.prank(searcher);
        positionRecipient.collectFees(FORK_TOKEN_ID);
    }

    function test_collectFees_transfersCurrencyFeesToCaller(uint256 _minTokenBurnAmount) public {
        vm.assume(_minTokenBurnAmount > 0 && _minTokenBurnAmount < 1_000_000e6);

        positionRecipient = new BuybackAndBurnPositionRecipient(
            USDC, NATIVE, operator, IPositionManager(POSITION_MANAGER), 0, _minTokenBurnAmount
        );
        vm.prank(searcher);
        IERC20(USDC).approve(address(positionRecipient), type(uint256).max);
        _dealUSDCFromPoolManager(address(searcher), _minTokenBurnAmount);

        _yoinkPosition(FORK_TOKEN_ID, address(positionRecipient));

        uint256 deadAddressTokenBalanceBefore = Currency.wrap(USDC).balanceOf(address(0xdead));

        vm.expectEmit(true, true, true, true);
        emit BuybackAndBurnPositionRecipient.TokensBurned(_minTokenBurnAmount);
        uint256 searcherCurrencyBalanceBefore = Currency.wrap(NATIVE).balanceOf(searcher);

        vm.prank(searcher);
        vm.expectEmit(true, true, true, true);
        emit BuybackAndBurnPositionRecipient.FeesCollected(searcher);
        positionRecipient.collectFees(FORK_TOKEN_ID);
        assertGt(
            Currency.wrap(NATIVE).balanceOf(searcher),
            searcherCurrencyBalanceBefore,
            "Searcher currency balance did not increase"
        );
        assertEq(
            Currency.wrap(USDC).balanceOf(address(positionRecipient)), 0, "Position recipient token balance is not 0"
        );
        assertEq(
            Currency.wrap(NATIVE).balanceOf(address(positionRecipient)),
            0,
            "Position recipient currency balance is not 0"
        );
        assertGt(
            Currency.wrap(USDC).balanceOf(address(0xdead)),
            deadAddressTokenBalanceBefore + _minTokenBurnAmount,
            "Dead address token balance did not increase by more than the minimum burn amount"
        );
    }
}
