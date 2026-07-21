// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseBuybackAndBurnPositionRecipient} from "../../src/periphery/BaseBuybackAndBurnPositionRecipient.sol";
import {
    CanonicalBuybackAndBurnPositionRecipient
} from "../../src/periphery/CanonicalBuybackAndBurnPositionRecipient.sol";
import {ITimelockedPositionRecipient} from "../../src/interfaces/ITimelockedPositionRecipient.sol";
import {TimelockedPositionRecipientTest} from "./TimelockedPositionRecipient.t.sol";

contract CanonicalBuybackAndBurnPositionRecipientTest is TimelockedPositionRecipientTest {
    uint256 internal constant FORK_BLOCK = 23936030;
    uint256 internal constant FORK_TOKEN_ID = 107192;
    uint256 internal constant FORK_CURRENCY_FEES_AMOUNT = 709706242928;

    CanonicalBuybackAndBurnPositionRecipient internal positionRecipient;

    function setUp() public override {
        super.setUp();
        vm.createSelectFork(vm.envString("QUICKNODE_RPC_URL"), FORK_BLOCK);
    }

    function _getPositionRecipient(uint64 _timelockBlockNumber)
        internal
        override
        returns (ITimelockedPositionRecipient)
    {
        return new CanonicalBuybackAndBurnPositionRecipient(
            IPositionManager(POSITION_MANAGER), operator, _timelockBlockNumber, 0
        );
    }

    function test_CanBeConstructed(uint256 _timelockBlockNumber, uint256 _minTokenBurnAmount) public {
        positionRecipient = new CanonicalBuybackAndBurnPositionRecipient(
            IPositionManager(POSITION_MANAGER), operator, _timelockBlockNumber, _minTokenBurnAmount
        );

        assertEq(positionRecipient.timelockBlockNumber(), _timelockBlockNumber);
        assertEq(positionRecipient.minTokenBurnAmount(), _minTokenBurnAmount);
        assertEq(Currency.unwrap(positionRecipient.currency()), NATIVE);
        assertEq(positionRecipient.operator(), operator);
        assertEq(address(positionRecipient.positionManager()), POSITION_MANAGER);
    }

    function test_collectFees_revertsIfPositionIsInvalid() public {
        positionRecipient =
            new CanonicalBuybackAndBurnPositionRecipient(IPositionManager(POSITION_MANAGER), operator, 0, 0);

        vm.expectRevert(
            abi.encodeWithSelector(BaseBuybackAndBurnPositionRecipient.InvalidPosition.selector, type(uint256).max)
        );
        positionRecipient.collectFees(type(uint256).max, 0);
    }

    function test_collectFees_revertsIfPositionIsNotOwner() public {
        positionRecipient =
            new CanonicalBuybackAndBurnPositionRecipient(IPositionManager(POSITION_MANAGER), operator, 0, 0);

        vm.expectRevert(abi.encodeWithSelector(IPositionManager.NotApproved.selector, address(positionRecipient)));
        positionRecipient.collectFees(FORK_TOKEN_ID, 0);
    }

    function test_collectFees_derivesTokenAndPreservesExistingETH(uint256 _minTokenBurnAmount) public {
        _minTokenBurnAmount = bound(_minTokenBurnAmount, 1, 1_000_000e6);
        positionRecipient = new CanonicalBuybackAndBurnPositionRecipient(
            IPositionManager(POSITION_MANAGER), operator, 0, _minTokenBurnAmount
        );

        vm.prank(searcher);
        IERC20(USDC).approve(address(positionRecipient), type(uint256).max);
        _dealUSDCFromPoolManager(searcher, _minTokenBurnAmount);
        _yoinkPosition(FORK_TOKEN_ID, address(positionRecipient));

        uint256 existingETH = 1 ether;
        vm.deal(address(positionRecipient), existingETH);
        uint256 searcherETHBefore = searcher.balance;
        uint256 burnAddressTokenBefore = IERC20(USDC).balanceOf(address(0xdead));

        vm.expectEmit(true, true, false, true);
        emit CanonicalBuybackAndBurnPositionRecipient.TokensBurned(
            FORK_TOKEN_ID, Currency.wrap(USDC), _minTokenBurnAmount
        );
        vm.expectEmit(true, true, true, true);
        emit CanonicalBuybackAndBurnPositionRecipient.FeesCollected(
            FORK_TOKEN_ID, searcher, Currency.wrap(USDC), FORK_CURRENCY_FEES_AMOUNT
        );
        vm.prank(searcher);
        positionRecipient.collectFees(FORK_TOKEN_ID, FORK_CURRENCY_FEES_AMOUNT);

        assertEq(address(positionRecipient).balance, existingETH);
        assertEq(searcher.balance - searcherETHBefore, FORK_CURRENCY_FEES_AMOUNT);
        assertGt(IERC20(USDC).balanceOf(address(0xdead)), burnAddressTokenBefore + _minTokenBurnAmount);
    }
}
