// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {BaseBuybackAndBurnPositionRecipient} from "../../src/periphery/BaseBuybackAndBurnPositionRecipient.sol";
import {
    CanonicalBuybackAndBurnPositionRecipient
} from "../../src/periphery/CanonicalBuybackAndBurnPositionRecipient.sol";
import {ITimelockedPositionRecipient} from "../../src/interfaces/ITimelockedPositionRecipient.sol";
import {TimelockedPositionRecipientTest} from "./TimelockedPositionRecipient.t.sol";
import {MockLPFeesExecutor, ILPFeesPositionRecipient} from "./MockLPFeesExecutor.sol";

contract CanonicalBuybackAndBurnPositionRecipientTest is TimelockedPositionRecipientTest {
    uint256 internal constant FORK_BLOCK = 23936030;
    uint256 internal constant FORK_TOKEN_ID = 107192;
    uint256 internal constant FORK_CURRENCY_FEES_AMOUNT = 709706242928;
    /// @dev An existing position at FORK_BLOCK whose currency0 is an ERC20, not native ETH
    uint256 internal constant NON_ETH_FORK_TOKEN_ID = 107193;
    address internal constant NON_ETH_FORK_CURRENCY0 = 0x18F52B3fb465118731d9e0d276d4Eb3599D57596;
    /// @dev An existing native ETH position at FORK_BLOCK in a different pool (ETH/UNI; UNI has
    ///      18 decimals, unlike USDC) with nonzero unclaimed fees, for cross-pool isolation coverage
    uint256 internal constant UNI_FORK_TOKEN_ID = 107094;
    uint256 internal constant UNI_FORK_CURRENCY_FEES_AMOUNT = 261556308004307;
    address internal constant UNI = 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984;

    CanonicalBuybackAndBurnPositionRecipient internal positionRecipient;
    MockLPFeesExecutor internal executor;

    function setUp() public override {
        super.setUp();
        vm.createSelectFork(vm.envString("QUICKNODE_RPC_URL"), FORK_BLOCK);
        executor = new MockLPFeesExecutor();
    }

    function _getPositionRecipient(uint64 _timelockBlockNumber)
        internal
        override
        returns (ITimelockedPositionRecipient)
    {
        return new CanonicalBuybackAndBurnPositionRecipient(
            IPositionManager(POSITION_MANAGER), operator, _timelockBlockNumber, 1
        );
    }

    function test_CanBeConstructed(uint256 _timelockBlockNumber, uint256 _minTokenBurnAmount) public {
        vm.assume(_minTokenBurnAmount > 0);
        positionRecipient = new CanonicalBuybackAndBurnPositionRecipient(
            IPositionManager(POSITION_MANAGER), operator, _timelockBlockNumber, _minTokenBurnAmount
        );

        assertEq(positionRecipient.timelockBlockNumber(), _timelockBlockNumber);
        assertEq(positionRecipient.minCurrency1BurnAmount(), _minTokenBurnAmount);
        assertEq(Currency.unwrap(positionRecipient.currency()), NATIVE);
        assertEq(positionRecipient.operator(), operator);
        assertEq(address(positionRecipient.positionManager()), POSITION_MANAGER);
    }

    function test_RevertsIfMinTokenBurnAmountIsZero(uint256 _timelockBlockNumber) public {
        vm.expectRevert(CanonicalBuybackAndBurnPositionRecipient.InvalidMinCurrency1BurnAmount.selector);
        new CanonicalBuybackAndBurnPositionRecipient(
            IPositionManager(POSITION_MANAGER), operator, _timelockBlockNumber, 0
        );
    }

    function test_collectFees_revertsIfPositionIsInvalid() public {
        positionRecipient =
            new CanonicalBuybackAndBurnPositionRecipient(IPositionManager(POSITION_MANAGER), operator, 0, 1);

        vm.expectRevert(
            abi.encodeWithSelector(BaseBuybackAndBurnPositionRecipient.InvalidPosition.selector, type(uint256).max)
        );
        positionRecipient.collectFees(type(uint256).max, 0, 0);
    }

    function test_collectFees_revertsIfPositionIsNotOwner() public {
        positionRecipient =
            new CanonicalBuybackAndBurnPositionRecipient(IPositionManager(POSITION_MANAGER), operator, 0, 1);

        // fund the caller-side burn so the revert under test (position authorization) is reached
        _dealUSDCFromPoolManager(address(this), 1);
        IERC20(USDC).approve(address(positionRecipient), 1);
        vm.expectRevert(abi.encodeWithSelector(IPositionManager.NotApproved.selector, address(positionRecipient)));
        positionRecipient.collectFees(FORK_TOKEN_ID, 0, 0);
    }

    function test_collectFees_derivesTokenAndPreservesExistingETH(uint256 _minTokenBurnAmount) public {
        _minTokenBurnAmount = bound(_minTokenBurnAmount, 1, 1_000_000e6);
        positionRecipient = new CanonicalBuybackAndBurnPositionRecipient(
            IPositionManager(POSITION_MANAGER), operator, 0, _minTokenBurnAmount
        );

        executor.approveToken(USDC, address(positionRecipient), type(uint256).max);
        _dealUSDCFromPoolManager(address(executor), _minTokenBurnAmount);
        _yoinkPosition(FORK_TOKEN_ID, address(positionRecipient));

        uint256 existingETH = 1 ether;
        vm.deal(address(positionRecipient), existingETH);
        uint256 executorETHBefore = address(executor).balance;
        uint256 burnAddressTokenBefore = IERC20(USDC).balanceOf(address(0xdead));

        vm.expectEmit(true, true, false, true);
        emit CanonicalBuybackAndBurnPositionRecipient.TokensBurned(
            FORK_TOKEN_ID, Currency.wrap(USDC), _minTokenBurnAmount
        );
        vm.expectEmit(true, false, false, false, address(positionRecipient));
        emit BaseBuybackAndBurnPositionRecipient.FeesCollected(
            FORK_TOKEN_ID, FORK_CURRENCY_FEES_AMOUNT, 0, _poolKey(FORK_TOKEN_ID)
        );
        executor.execute(
            ILPFeesPositionRecipient(address(positionRecipient)), FORK_TOKEN_ID, FORK_CURRENCY_FEES_AMOUNT, 0
        );

        assertEq(address(positionRecipient).balance, existingETH);
        assertEq(address(executor).balance - executorETHBefore, FORK_CURRENCY_FEES_AMOUNT);
        assertEq(IERC20(USDC).balanceOf(address(0xdead)), burnAddressTokenBefore + _minTokenBurnAmount);
    }

    // Deal an arbitrary pool token from the pool manager to an address (same pattern as
    // _dealUSDCFromPoolManager; the pool manager custodies every v4 pool's reserves)
    function _dealTokenFromPoolManager(address _token, address _to, uint256 _amount) internal {
        vm.prank(POOL_MANAGER);
        bool success = IERC20(_token).transfer(_to, _amount);
        assertTrue(success);
    }

    function test_collectFees_revertsIfCurrencyIsNotNative() public {
        positionRecipient =
            new CanonicalBuybackAndBurnPositionRecipient(IPositionManager(POSITION_MANAGER), operator, 0, 1);
        _yoinkPosition(NON_ETH_FORK_TOKEN_ID, address(positionRecipient));

        vm.expectRevert(
            abi.encodeWithSelector(
                CanonicalBuybackAndBurnPositionRecipient.InvalidCurrency.selector,
                Currency.wrap(NON_ETH_FORK_CURRENCY0),
                Currency.wrap(NATIVE)
            )
        );
        executor.execute(ILPFeesPositionRecipient(address(positionRecipient)), NON_ETH_FORK_TOKEN_ID, 0, 0);
    }

    function test_collectFees_revertsIfInsufficientCurrencyReceived(uint256 _minCurrencyAmount) public {
        _minCurrencyAmount = _bound(_minCurrencyAmount, FORK_CURRENCY_FEES_AMOUNT + 1, type(uint256).max);

        positionRecipient =
            new CanonicalBuybackAndBurnPositionRecipient(IPositionManager(POSITION_MANAGER), operator, 0, 1);
        executor.approveToken(USDC, address(positionRecipient), type(uint256).max);
        _dealUSDCFromPoolManager(address(executor), 1);
        _yoinkPosition(FORK_TOKEN_ID, address(positionRecipient));

        vm.expectRevert(
            abi.encodeWithSelector(
                BaseBuybackAndBurnPositionRecipient.InsufficientAmountReceived.selector,
                Currency.wrap(NATIVE),
                FORK_CURRENCY_FEES_AMOUNT,
                _minCurrencyAmount
            )
        );
        executor.execute(ILPFeesPositionRecipient(address(positionRecipient)), FORK_TOKEN_ID, _minCurrencyAmount, 0);
    }

    function test_collectFees_isolatesFeesAcrossPools() public {
        positionRecipient =
            new CanonicalBuybackAndBurnPositionRecipient(IPositionManager(POSITION_MANAGER), operator, 0, 1);

        // One singleton instance holds positions from two different ETH-paired pools,
        // one of them with an 18-decimal token (UNI)
        _yoinkPosition(FORK_TOKEN_ID, address(positionRecipient));
        _yoinkPosition(UNI_FORK_TOKEN_ID, address(positionRecipient));

        executor.approveToken(USDC, address(positionRecipient), type(uint256).max);
        executor.approveToken(UNI, address(positionRecipient), type(uint256).max);
        _dealUSDCFromPoolManager(address(executor), 1);
        _dealTokenFromPoolManager(UNI, address(executor), 1);

        uint256 executorETHBefore = address(executor).balance;
        uint256 recipientETHBefore = address(positionRecipient).balance;
        uint256 burnAddressUNIBefore = IERC20(UNI).balanceOf(address(0xdead));

        // Collecting the ETH/UNI position pays out exactly its own fees; the min doubles as a floor
        executor.execute(
            ILPFeesPositionRecipient(address(positionRecipient)), UNI_FORK_TOKEN_ID, UNI_FORK_CURRENCY_FEES_AMOUNT, 0
        );

        assertEq(address(executor).balance - executorETHBefore, UNI_FORK_CURRENCY_FEES_AMOUNT);
        assertEq(address(positionRecipient).balance, recipientETHBefore);
        assertGt(IERC20(UNI).balanceOf(address(0xdead)), burnAddressUNIBefore);

        // The other pool's position is untouched and still collectable for its exact amount
        executor.execute(
            ILPFeesPositionRecipient(address(positionRecipient)), FORK_TOKEN_ID, FORK_CURRENCY_FEES_AMOUNT, 0
        );

        assertEq(
            address(executor).balance - executorETHBefore, UNI_FORK_CURRENCY_FEES_AMOUNT + FORK_CURRENCY_FEES_AMOUNT
        );
        assertEq(address(positionRecipient).balance, recipientETHBefore);
    }

    function test_withdrawInvalidPosition_transfersToOperatorBeforeTimelock() public {
        positionRecipient = new CanonicalBuybackAndBurnPositionRecipient(
            IPositionManager(POSITION_MANAGER), operator, type(uint64).max, 1
        );
        _yoinkPosition(NON_ETH_FORK_TOKEN_ID, address(positionRecipient));

        // The timelock is far in the future; rescue must not depend on it
        assertLt(block.number, positionRecipient.timelockBlockNumber());

        vm.expectEmit(true, false, false, true);
        emit CanonicalBuybackAndBurnPositionRecipient.InvalidPositionWithdrawn(
            NON_ETH_FORK_TOKEN_ID, Currency.wrap(NON_ETH_FORK_CURRENCY0)
        );
        vm.prank(searcher);
        positionRecipient.withdrawInvalidPosition(NON_ETH_FORK_TOKEN_ID);

        assertEq(IERC721(POSITION_MANAGER).ownerOf(NON_ETH_FORK_TOKEN_ID), operator);
    }

    function test_withdrawInvalidPosition_revertsIfPositionIsConforming() public {
        positionRecipient = new CanonicalBuybackAndBurnPositionRecipient(
            IPositionManager(POSITION_MANAGER), operator, type(uint64).max, 1
        );
        _yoinkPosition(FORK_TOKEN_ID, address(positionRecipient));

        vm.expectRevert(
            abi.encodeWithSelector(CanonicalBuybackAndBurnPositionRecipient.PositionConforming.selector, FORK_TOKEN_ID)
        );
        positionRecipient.withdrawInvalidPosition(FORK_TOKEN_ID);

        assertEq(IERC721(POSITION_MANAGER).ownerOf(FORK_TOKEN_ID), address(positionRecipient));
    }

    function test_withdrawInvalidPosition_revertsIfPositionIsInvalid() public {
        positionRecipient = new CanonicalBuybackAndBurnPositionRecipient(
            IPositionManager(POSITION_MANAGER), operator, type(uint64).max, 1
        );

        vm.expectRevert(
            abi.encodeWithSelector(BaseBuybackAndBurnPositionRecipient.InvalidPosition.selector, type(uint256).max)
        );
        positionRecipient.withdrawInvalidPosition(type(uint256).max);
    }

    function test_withdrawInvalidPosition_revertsIfPositionIsNotOwned() public {
        positionRecipient = new CanonicalBuybackAndBurnPositionRecipient(
            IPositionManager(POSITION_MANAGER), operator, type(uint64).max, 1
        );

        // The recipient neither owns nor is approved for the position
        vm.expectRevert(bytes("WRONG_FROM"));
        positionRecipient.withdrawInvalidPosition(NON_ETH_FORK_TOKEN_ID);
    }

    function _poolKey(uint256 tokenId) internal view returns (PoolKey memory poolKey) {
        (poolKey,) = IPositionManager(POSITION_MANAGER).getPoolAndPositionInfo(tokenId);
    }
}
