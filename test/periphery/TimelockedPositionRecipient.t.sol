// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {TimelockedPositionRecipient} from "../../src/periphery/TimelockedPositionRecipient.sol";
import {ITimelockedPositionRecipient} from "../../src/interfaces/ITimelockedPositionRecipient.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

contract TimelockedPositionRecipientTest is Test {
    address operator;
    address searcher;

    // Constants
    address constant POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant NATIVE = 0x0000000000000000000000000000000000000000;

    // Shared fork fixture for position recipient tests
    // Position created here: https://etherscan.io/tx/0x03dafd828c6b47362b1f53d7a692f8f52b8bc44b513f8c9caa9195e1061113a4
    // And the fork block is a few blocks after, allowing the position to have non zero fees
    uint256 internal constant FORK_BLOCK = 23936030;
    uint256 internal constant FORK_TOKEN_ID = 107192;
    uint256 internal constant FORK_CURRENCY0_FEES_AMOUNT = 709706242928;

    // Transfer a v4 position from one owner to another
    function _yoinkPosition(uint256 _tokenId, address _newOwner) internal {
        address originalOwner = IERC721(POSITION_MANAGER).ownerOf(_tokenId);
        vm.prank(originalOwner);
        IERC721(POSITION_MANAGER).transferFrom(originalOwner, _newOwner, _tokenId);
        assertEq(IERC721(POSITION_MANAGER).ownerOf(_tokenId), _newOwner);
    }

    // Deal a pool token from the pool manager to an address
    // (the pool manager custodies every v4 pool's reserves; vm.deal() doesn't work well for proxied tokens)
    function _dealTokenFromPoolManager(address _token, address _to, uint256 _amount) internal {
        vm.prank(POOL_MANAGER);
        bool success = IERC20(_token).transfer(_to, _amount);
        assertTrue(success);
    }

    function _dealUSDCFromPoolManager(address _to, uint256 _amount) internal {
        _dealTokenFromPoolManager(USDC, _to, _amount);
    }

    function _poolKey(uint256 _tokenId) internal view returns (PoolKey memory poolKey) {
        (poolKey,) = IPositionManager(POSITION_MANAGER).getPoolAndPositionInfo(_tokenId);
    }

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
