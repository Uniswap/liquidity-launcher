// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TimelockedPositionRecipient} from "../../src/periphery/TimelockedPositionRecipient.sol";
import {ITimelockedPositionRecipient} from "../../src/interfaces/ITimelockedPositionRecipient.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {PositionRecipientTestBase} from "./PositionRecipientTestBase.sol";

contract TimelockedPositionRecipientTest is PositionRecipientTestBase {
    address operator;

    function setUp() public override {
        super.setUp();
        operator = makeAddr("operator");
        vm.label(operator, "operator");
    }

    function _getPositionRecipient(uint64 _timelockBlockNumber) internal returns (ITimelockedPositionRecipient) {
        return new TimelockedPositionRecipient(IPositionManager(POSITION_MANAGER), operator, _timelockBlockNumber);
    }

    function test_CanBeConstructed(uint64 _timelockBlockNumber) public {
        ITimelockedPositionRecipient positionRecipient = _getPositionRecipient(_timelockBlockNumber);

        assertEq(positionRecipient.timelockBlockNumber(), _timelockBlockNumber);
        assertEq(positionRecipient.operator(), operator);
        assertEq(address(positionRecipient.positionManager()), POSITION_MANAGER);
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

    function test_approveOperator_transferFrom_revertsIfPositionIsTimelocked(uint64 _timelockBlockNumber) public {
        vm.assume(_timelockBlockNumber > 0);

        ITimelockedPositionRecipient positionRecipient = _getPositionRecipient(_timelockBlockNumber);

        vm.roll(uint256(_timelockBlockNumber) + 1);

        positionRecipient.approveOperator();

        // Give a position to the position recipient
        uint256 tokenId = 1;
        _yoinkPosition(tokenId, address(positionRecipient));

        address to = makeAddr("to");
        vm.prank(operator);
        IERC721(POSITION_MANAGER).transferFrom(address(positionRecipient), to, tokenId);
        assertEq(IERC721(POSITION_MANAGER).ownerOf(tokenId), to);
    }
}
