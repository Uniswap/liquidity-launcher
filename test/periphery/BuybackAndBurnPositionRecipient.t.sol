// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {BuybackAndBurnPositionRecipient} from "../../src/periphery/BuybackAndBurnPositionRecipient.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC721} from "../../src/interfaces/external/IERC721.sol";
import {TimelockedPositionRecipient} from "../../src/periphery/TimelockedPositionRecipient.sol";

// Minimal interfaces for testing
interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

contract BuybackAndBurnPositionRecipientTest is Test {
    using CurrencyLibrary for Currency;

    BuybackAndBurnPositionRecipient public positionRecipient;

    // Constants
    address constant POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    // Fork testing vars
    // Position created here: https://etherscan.io/tx/0x03dafd828c6b47362b1f53d7a692f8f52b8bc44b513f8c9caa9195e1061113a4
    // And the fork block is a few blocks after, allowing the position to have non zero fees
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant NATIVE = 0x0000000000000000000000000000000000000000;
    uint256 constant FORK_BLOCK = 23936030;
    uint256 constant FORK_TOKEN_ID = 107192;

    MockERC20 token;
    MockERC20 currency;
    address operator;
    address searcher;

    function setUp() public virtual {
        vm.createSelectFork(vm.envString("QUICKNODE_RPC_URL"), FORK_BLOCK);
        token = new MockERC20("Test Token", "TEST", 1_000e18, address(this));
        currency = new MockERC20("Test Currency", "TESTC", 1_000e18, address(this));
        operator = makeAddr("operator");
        searcher = makeAddr("searcher");

        vm.label(operator, "operator");
        vm.label(searcher, "searcher");
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

    function test_CanBeConstructed(uint256 _timelockBlockNumber, uint256 _minTokenBurnAmount) public {
        positionRecipient = new BuybackAndBurnPositionRecipient(
            address(token),
            address(currency),
            operator,
            IPositionManager(POSITION_MANAGER),
            _timelockBlockNumber,
            _minTokenBurnAmount
        );

        assertEq(positionRecipient.TIMELOCK_BLOCK_NUMBER(), _timelockBlockNumber);
        assertEq(positionRecipient.MIN_TOKEN_BURN_AMOUNT(), _minTokenBurnAmount);
        assertEq(positionRecipient.TOKEN(), address(token));
        assertEq(positionRecipient.CURRENCY(), address(currency));
        assertEq(positionRecipient.OPERATOR(), operator);
        assertEq(address(positionRecipient.POSITION_MANAGER()), POSITION_MANAGER);
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

    function test_CanReceiveETH() public {
        positionRecipient = new BuybackAndBurnPositionRecipient(
            address(token), address(currency), operator, IPositionManager(POSITION_MANAGER), 0, 0
        );
        assertEq(address(positionRecipient).balance, 0);
        vm.deal(address(this), 1 ether);
        (bool success,) = address(positionRecipient).call{value: 1 ether}("");
        assertTrue(success);
        assertEq(address(positionRecipient).balance, 1 ether);
    }

    function test_approveOperator_revertsIfPositionIsTimelocked(uint256 _blockNumber, uint256 _timelockBlockNumber)
        public
    {
        vm.assume(_timelockBlockNumber > 0);

        positionRecipient = new BuybackAndBurnPositionRecipient(
            address(token), address(currency), operator, IPositionManager(POSITION_MANAGER), _timelockBlockNumber, 0
        );

        uint256 blockNumber = _bound(_blockNumber, 0, _timelockBlockNumber - 1);
        vm.roll(blockNumber);
        vm.expectRevert(TimelockedPositionRecipient.Timelocked.selector);
        positionRecipient.approveOperator();
    }

    function test_approveOperator(uint64 _timelockBlockNumber) public {
        vm.assume(_timelockBlockNumber > 0);

        positionRecipient = new BuybackAndBurnPositionRecipient(
            address(token), address(currency), operator, IPositionManager(POSITION_MANAGER), _timelockBlockNumber, 0
        );

        // Transfer the position to the position recipient
        _yoinkPosition(FORK_TOKEN_ID, address(positionRecipient));

        vm.roll(uint256(_timelockBlockNumber) + 1);

        // Approve the operator to transfer the position
        vm.expectEmit(true, true, true, true);
        emit TimelockedPositionRecipient.OperatorApproved(operator);
        positionRecipient.approveOperator();
    }

    function test_collectFees_revertsIfPositionIsNotOwner() public {
        positionRecipient =
            new BuybackAndBurnPositionRecipient(USDC, NATIVE, operator, IPositionManager(POSITION_MANAGER), 0, 0);
        vm.expectRevert(BuybackAndBurnPositionRecipient.NotPositionOwner.selector);
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
