// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {TimelockedPositionRecipient} from "../../src/periphery/TimelockedPositionRecipient.sol";
import {ITimelockedPositionRecipient} from "../../src/interfaces/ITimelockedPositionRecipient.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

contract TimelockedPositionRecipientTest is Test {
    address operator;
    address searcher;

    // Constants
    address constant POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /// @dev Override this with a default instance of a position recipient to test timelock functionality
    function _getPositionRecipient(uint64 _timelockBlockNumber)
        internal
        virtual
        returns (ITimelockedPositionRecipient)
    {
        return new TimelockedPositionRecipient(IPositionManager(POSITION_MANAGER), operator, _timelockBlockNumber);
    }

    function setUp() public virtual {
        vm.createSelectFork(vm.envString("QUICKNODE_RPC_URL"));
        operator = makeAddr("operator");
        searcher = makeAddr("searcher");

        vm.label(operator, "operator");
        vm.label(searcher, "searcher");
    }

    function test_CanBeConstructed(uint64 _timelockBlockNumber) public {
        ITimelockedPositionRecipient positionRecipient = _getPositionRecipient(_timelockBlockNumber);

        assertEq(positionRecipient.TIMELOCK_BLOCK_NUMBER(), _timelockBlockNumber);
        assertEq(positionRecipient.OPERATOR(), operator);
        assertEq(address(positionRecipient.POSITION_MANAGER()), POSITION_MANAGER);
    }

    function test_CanReceiveETH(uint64 _timelockBlockNumber) public {
        ITimelockedPositionRecipient positionRecipient = _getPositionRecipient(_timelockBlockNumber);
        uint256 balanceBefore = address(positionRecipient).balance;
        vm.deal(address(this), 1 ether);
        (bool success,) = address(positionRecipient).call{value: 1 ether}("");
        assertTrue(success);
        assertEq(address(positionRecipient).balance, balanceBefore + 1 ether);
    }

    function test_approveOperator_revertsIfPositionIsTimelocked(uint256 _blockNumber, uint64 _timelockBlockNumber)
        public
    {
        vm.assume(_timelockBlockNumber > 0);

        ITimelockedPositionRecipient positionRecipient = _getPositionRecipient(_timelockBlockNumber);

        uint256 blockNumber = _bound(_blockNumber, 0, uint256(_timelockBlockNumber) - 1);
        vm.roll(blockNumber);
        vm.expectRevert(ITimelockedPositionRecipient.Timelocked.selector);
        positionRecipient.approveOperator();
    }

    function test_approveOperator(uint64 _timelockBlockNumber) public {
        vm.assume(_timelockBlockNumber > 0);

        ITimelockedPositionRecipient positionRecipient = _getPositionRecipient(_timelockBlockNumber);

        vm.roll(uint256(_timelockBlockNumber) + 1);

        // Approve the operator to transfer the position
        vm.expectEmit(true, true, true, true);
        emit ITimelockedPositionRecipient.OperatorApproved(operator);
        positionRecipient.approveOperator();
    }
}
